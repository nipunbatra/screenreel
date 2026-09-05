import XCTest

@testable import EventCapture
@testable import ProjectModel

actor ChunkCollector {
    private(set) var committed: [EventChunkDescriptor] = []
    func note(_ chunk: EventChunkDescriptor) { committed.append(chunk) }
}

final class EventCaptureTests: XCTestCase {
    private var directory: URL!
    private var layout: ProjectLayout!

    override func setUp() {
        super.setUp()
        AtomicFile.fullFsync = false
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("screenreel-events-\(UUID().uuidString).screenreel")
        layout = ProjectLayout(root: directory)
        for dir in layout.initialDirectories {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        AtomicFile.fullFsync = true
        super.tearDown()
    }

    func testChunkStoreAssignsSequencesAndCommitsAtomically() async throws {
        let collector = ChunkCollector()
        let cursorTrack = UUID()
        let clickTrack = UUID()
        let store = EventChunkStore(
            layout: layout,
            trackIDs: [.cursor: cursorTrack, .clicks: clickTrack],
            maxRecordsPerChunk: 10,
            onCommit: { chunk in await collector.note(chunk) })

        // 25 cursor moves and 4 click events, interleaved.
        for index in 0..<25 {
            try await store.append(EventRecord(
                sequence: 0, timeNs: Int64(index) * 10_000_000, type: .cursorMove,
                displayID: 1, xPx: Double(index), yPx: 1, cursorID: "a", buttons: 0))
            if index % 8 == 0 {
                try await store.append(EventRecord(
                    sequence: 0, timeNs: Int64(index) * 10_000_000 + 1, type: .mouseDown,
                    displayID: 1, xPx: Double(index), yPx: 1, cursorID: "a", button: .left))
            }
        }
        try await store.finish()

        let committed = await collector.committed
        let cursorChunks = committed.filter { $0.kind == .cursor }
        let clickChunks = committed.filter { $0.kind == .clicks }
        XCTAssertEqual(cursorChunks.count, 3)  // 10 + 10 + 5
        XCTAssertEqual(clickChunks.count, 1)
        XCTAssertEqual(cursorChunks.map(\.sequenceInTrack), [1, 2, 3])
        XCTAssertEqual(cursorChunks.reduce(0) { $0 + $1.recordCount }, 25)
        XCTAssertEqual(clickChunks.first?.recordCount, 4)

        // The global sequence spans kinds with no duplicates or gaps.
        var allSequences: [UInt64] = []
        for chunk in committed {
            let url = try layout.resolve(relativePath: chunk.path)
            let data = try Data(contentsOf: url)
            XCTAssertEqual(Int64(data.count), chunk.byteSize)
            XCTAssertEqual(Hashing.sha256Hex(data), chunk.sha256)
            let text = try XCTUnwrap(String(data: data, encoding: .utf8))
            var lineNumber = 0
            for line in text.split(separator: "\n") {
                lineNumber += 1
                let record = try EventRecord.parse(line: line, lineNumber: lineNumber)
                allSequences.append(record.sequence)
                XCTAssertTrue(record.structuralProblems().isEmpty)
            }
        }
        XCTAssertEqual(allSequences.sorted(), Array(1...29).map(UInt64.init))

        // No partial files remain.
        let leftovers = try FileManager.default
            .contentsOfDirectory(atPath: layout.eventsDirectory.path)
            .filter { $0.hasSuffix(".partial") }
        XCTAssertTrue(leftovers.isEmpty)
    }

    /// A chunk-commit failure must never lose records: the batch is restored
    /// in order and the next commit retries the same chunk index.
    func testCommitFailureRetainsRecordsForRetry() async throws {
        final class FailOnce: @unchecked Sendable {
            private let lock = NSLock()
            private var failed = false
            func shouldFail() -> Bool {
                lock.lock()
                defer { lock.unlock() }
                if failed { return false }
                failed = true
                return true
            }
        }
        let failOnce = FailOnce()
        let collector = ChunkCollector()
        let store = EventChunkStore(
            layout: layout,
            trackIDs: [.cursor: UUID()],
            maxRecordsPerChunk: 5,
            onCommit: { chunk in
                if failOnce.shouldFail() {
                    throw ScreenreelError.invariantViolated("simulated journal failure")
                }
                await collector.note(chunk)
            })

        var sawFailure = false
        for index in 0..<12 {
            do {
                try await store.append(EventRecord(
                    sequence: 0, timeNs: Int64(index), type: .cursorMove,
                    displayID: 1, xPx: 0, yPx: 0, cursorID: "a", buttons: 0))
            } catch {
                sawFailure = true  // surfaced, not swallowed
            }
        }
        try await store.finish()
        XCTAssertTrue(sawFailure)

        // Every appended record ends up committed exactly once, in order.
        let committed = await collector.committed
        var sequences: [UInt64] = []
        for chunk in committed {
            let url = try layout.resolve(relativePath: chunk.path)
            let text = try String(contentsOf: url, encoding: .utf8)
            for (offset, line) in text.split(separator: "\n").enumerated() {
                sequences.append(try EventRecord.parse(line: line, lineNumber: offset + 1).sequence)
            }
        }
        XCTAssertEqual(sequences, Array(1...12).map(UInt64.init))
        XCTAssertEqual(committed.map(\.sequenceInTrack), committed.map(\.sequenceInTrack).sorted())
    }

    func testUncapturedKindIsDropped() async throws {
        let collector = ChunkCollector()
        let store = EventChunkStore(
            layout: layout,
            trackIDs: [.cursor: UUID()],  // no keyboard track registered
            onCommit: { chunk in await collector.note(chunk) })
        try await store.append(EventRecord(sequence: 0, timeNs: 1, type: .keyDown, keyCode: 4))
        try await store.finish()
        let committed = await collector.committed
        XCTAssertTrue(committed.isEmpty)
    }

    func testSyntheticEventSourceIsDeterministic() async throws {
        let reference = SyntheticEventSource(durationNs: 2_500_000_000)
        func run() async -> [EventRecord] {
            let source = SyntheticEventSource(durationNs: 2_500_000_000)
            let collector = OSAllocatedRecords()
            source.start { record in collector.append(record) }
            await source.waitUntilFinished()
            return collector.snapshot()
        }
        let first = await run()
        let second = await run()
        XCTAssertEqual(first, second)
        XCTAssertFalse(first.isEmpty)

        let moves = first.filter { $0.type == .cursorMove }
        XCTAssertEqual(moves.count, reference.expectedMoveCount)
        let downs = first.filter { $0.type == .mouseDown }
        XCTAssertEqual(downs.count, reference.expectedClickCount)
        // Position matches the documented pure function of time.
        let expected = SyntheticEventSource.position(
            atNs: moves[5].timeNs, widthPx: 1920, heightPx: 1080)
        XCTAssertEqual(moves[5].xPx, expected.x)
        XCTAssertEqual(moves[5].yPx, expected.y)
    }
}

/// Thread-safe record accumulator for synchronous handlers.
final class OSAllocatedRecords: @unchecked Sendable {
    private let lock = NSLock()
    private var records: [EventRecord] = []

    func append(_ record: EventRecord) {
        lock.lock()
        records.append(record)
        lock.unlock()
    }

    func snapshot() -> [EventRecord] {
        lock.lock()
        defer { lock.unlock() }
        return records
    }
}
