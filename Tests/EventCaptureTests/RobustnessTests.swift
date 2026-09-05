import XCTest

@testable import EventCapture
@testable import ProjectModel

private actor StressChunkCollector {
    private(set) var chunks: [EventChunkDescriptor] = []

    func append(_ chunk: EventChunkDescriptor) {
        chunks.append(chunk)
    }
}

final class EventCaptureRobustnessTests: XCTestCase {
    private var directory: URL!
    private var layout: ProjectLayout!

    override func setUp() {
        super.setUp()
        AtomicFile.fullFsync = false
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("screenreel-event-stress-\(UUID().uuidString).screenreel")
        layout = ProjectLayout(root: directory)
        for url in layout.initialDirectories {
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        AtomicFile.fullFsync = true
        super.tearDown()
    }

    func testTenThousandEventsCommitExactlyOnceWithoutPartialTails() async throws {
        let collector = StressChunkCollector()
        let store = EventChunkStore(
            layout: layout,
            trackIDs: [.cursor: UUID()],
            maxRecordsPerChunk: 100,
            maxChunkSpanNs: Int64.max,
            onCommit: { chunk in await collector.append(chunk) })

        // Deliberately append serially from this single task so the expected
        // global order is exact and independent of scheduling.
        for index in 0..<10_000 {
            try await store.append(EventRecord(
                sequence: 0, timeNs: Int64(index), type: .cursorMove,
                displayID: 1, xPx: Double(index % 1920), yPx: Double(index % 1080),
                cursorID: "arrow", buttons: 0))
        }
        try await store.finish()

        let chunks = await collector.chunks.sorted { $0.sequenceInTrack < $1.sequenceInTrack }
        XCTAssertEqual(chunks.count, 100)
        XCTAssertEqual(chunks.map(\.sequenceInTrack), Array(1...100))
        XCTAssertTrue(chunks.allSatisfy { $0.recordCount == 100 })

        var sequences: [UInt64] = []
        sequences.reserveCapacity(10_000)
        for chunk in chunks {
            let url = try layout.resolve(relativePath: chunk.path)
            let bytes = try Data(contentsOf: url)
            XCTAssertEqual(Int64(bytes.count), chunk.byteSize)
            XCTAssertEqual(Hashing.sha256Hex(bytes), chunk.sha256)
            let text = try XCTUnwrap(String(data: bytes, encoding: .utf8))
            for (offset, line) in text.split(separator: "\n").enumerated() {
                let record = try EventRecord.parse(line: line, lineNumber: offset + 1)
                sequences.append(record.sequence)
            }
        }
        XCTAssertEqual(sequences, Array(1...10_000).map(UInt64.init))
        XCTAssertEqual(Set(sequences).count, 10_000)

        let partials = try FileManager.default.contentsOfDirectory(
            at: layout.eventsDirectory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasSuffix(ProjectLayout.partialSuffix) }
        XCTAssertTrue(partials.isEmpty, "leftover partial chunks: \(partials)")
    }
}
