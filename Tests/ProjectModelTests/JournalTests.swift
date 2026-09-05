import XCTest

@testable import ProjectModel

final class JournalTests: XCTestCase {
    private var directory: URL!

    override func setUp() {
        super.setUp()
        AtomicFile.fullFsync = false  // speed; durability semantics tested elsewhere
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("screenreel-journal-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        AtomicFile.fullFsync = true
        super.tearDown()
    }

    private var journalURL: URL { directory.appendingPathComponent("journal.jsonl") }

    private func writeRecords(_ count: Int) async throws -> JournalWriter {
        let writer = try JournalWriter(creatingAt: journalURL)
        for index in 0..<count {
            try await writer.append(
                type: .fault,
                timeNs: Int64(index) * 1_000,
                payload: JournalPayload.fault(kind: "test", message: "record \(index)"),
                durable: false)
        }
        return writer
    }

    func testAppendAndScanRoundTrip() async throws {
        _ = try await writeRecords(5)
        let scan = try JournalReader.scan(url: journalURL)
        XCTAssertNil(scan.truncationReason)
        XCTAssertEqual(scan.records.count, 5)
        XCTAssertEqual(scan.records.map(\.sequence), [1, 2, 3, 4, 5])
        XCTAssertEqual(scan.records.first?.prevHash, journalGenesisHash)
        for pair in zip(scan.records, scan.records.dropFirst()) {
            XCTAssertEqual(pair.0.hash, pair.1.prevHash)
        }
    }

    func testTornTrailingLineYieldsTrustedPrefix() async throws {
        _ = try await writeRecords(3)
        let handle = try FileHandle(forWritingTo: journalURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(#"{"schemaVersion":1,"sequence":4,"ty"#.utf8))
        try handle.close()

        let scan = try JournalReader.scan(url: journalURL)
        XCTAssertEqual(scan.records.count, 3)
        XCTAssertNotNil(scan.truncationReason)
        XCTAssertEqual(scan.truncatedAtLine, 4)
    }

    func testTamperedPayloadBreaksChecksum() async throws {
        _ = try await writeRecords(3)
        var text = try String(contentsOf: journalURL, encoding: .utf8)
        text = text.replacingOccurrences(of: "record 1", with: "record X")
        try Data(text.utf8).write(to: journalURL)

        let scan = try JournalReader.scan(url: journalURL)
        XCTAssertEqual(scan.records.count, 1)  // only the untampered first record
        XCTAssertTrue(scan.truncationReason?.contains("checksum") ?? false)
    }

    func testDeletedMiddleLineBreaksChain() async throws {
        _ = try await writeRecords(3)
        let lines = try String(contentsOf: journalURL, encoding: .utf8)
            .split(separator: "\n")
        let withoutSecond = [lines[0], lines[2]].joined(separator: "\n") + "\n"
        try Data(withoutSecond.utf8).write(to: journalURL)

        let scan = try JournalReader.scan(url: journalURL)
        XCTAssertEqual(scan.records.count, 1)
        XCTAssertTrue(scan.truncationReason?.contains("sequence gap") ?? false)
    }

    func testResumeContinuesChain() async throws {
        _ = try await writeRecords(2)
        let resumed = try JournalWriter(resumingAt: journalURL)
        try await resumed.append(
            type: .sessionStopped, timeNs: 99, payload: JournalPayload.empty(), durable: false)
        let scan = try JournalReader.scan(url: journalURL)
        XCTAssertNil(scan.truncationReason)
        XCTAssertEqual(scan.records.count, 3)
        XCTAssertEqual(scan.records.last?.type, .sessionStopped)
    }

    func testResumeRefusesBrokenTail() async throws {
        _ = try await writeRecords(2)
        let handle = try FileHandle(forWritingTo: journalURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("garbage".utf8))
        try handle.close()
        XCTAssertThrowsError(try JournalWriter(resumingAt: journalURL))
    }

    func testReplayVerifiedRebuildsIdenticalFile() async throws {
        _ = try await writeRecords(4)
        let originalData = try Data(contentsOf: journalURL)
        let scan = try JournalReader.scan(url: journalURL)

        let copyURL = directory.appendingPathComponent("copy.jsonl")
        let copier = try JournalWriter(creatingAt: copyURL)
        for record in scan.records {
            try await copier.replayVerified(record)
        }
        XCTAssertEqual(try Data(contentsOf: copyURL), originalData)
    }

    func testNewerSchemaVersionStopsScan() async throws {
        _ = try await writeRecords(1)
        let scan = try JournalReader.scan(url: journalURL)
        var line = try String(contentsOf: journalURL, encoding: .utf8)
        // Forge a plausible next record with a future schema version.
        line += line
            .split(separator: "\n")[0]
            .replacingOccurrences(of: "\"schemaVersion\":1", with: "\"schemaVersion\":99")
            .replacingOccurrences(of: "\"sequence\":1", with: "\"sequence\":2")
            + "\n"
        try Data(line.utf8).write(to: journalURL)
        let rescanned = try JournalReader.scan(url: journalURL)
        XCTAssertEqual(rescanned.records.count, scan.records.count)
        XCTAssertTrue(rescanned.truncationReason?.contains("newer") ?? false)
    }
}
