import XCTest

@testable import ProjectModel

final class AtomicFileAndStoreTests: XCTestCase {
    private var directory: URL!

    override func setUp() {
        super.setUp()
        AtomicFile.fullFsync = false
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("screenreel-atomic-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        AtomicFile.fullFsync = true
        super.tearDown()
    }

    func testWriteReplacesAtomicallyAndCleansTmp() throws {
        let url = directory.appendingPathComponent("value.json")
        try AtomicFile.write(Data("one".utf8), to: url)
        try AtomicFile.write(Data("two".utf8), to: url)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "two")
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path + ".tmp"))
    }

    func testStaleTmpFromCrashIsOverwritten() throws {
        let url = directory.appendingPathComponent("value.json")
        try Data("torn garbage".utf8).write(to: url.appendingPathExtension("tmp"))
        try AtomicFile.write(Data("clean".utf8), to: url)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "clean")
    }

    func testDurableAppendFile() throws {
        let url = directory.appendingPathComponent("log.jsonl")
        let file = try DurableAppendFile(url: url)
        try file.append(Data("a\n".utf8), durable: false)
        try file.append(Data("b\n".utf8), durable: true)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "a\nb\n")
    }

    func testManifestStoreGenerationsAndHistory() async throws {
        let layout = ProjectLayout(root: directory)
        let clock = ClockAnchor(
            originContinuousTicks: 1, originAbsoluteTicks: 1,
            timebaseNumer: 125, timebaseDenom: 3, originWallTime: RFC3339.now())
        let store = ManifestStore(layout: layout, manifest: Manifest(state: .recording, clock: clock))
        try await store.saveInitial()

        for index in 0..<4 {
            _ = try await store.save { $0.durationNs = Int64(index) }
        }
        let manifest = await store.manifest
        XCTAssertEqual(manifest.generation, 5)

        // Only the previous two generations are retained.
        let history = try FileManager.default
            .contentsOfDirectory(at: layout.historyDirectory, includingPropertiesForKeys: nil)
            .map(\.lastPathComponent).sorted()
        XCTAssertEqual(history, ["manifest-3.json", "manifest-4.json"])

        try await store.clearHistoryAfterCleanClose()
        XCTAssertFalse(FileManager.default.fileExists(atPath: layout.historyDirectory.path))
    }

    func testManifestRejectsNewerSchema() throws {
        var manifest = Manifest(
            state: .ready,
            clock: ClockAnchor(
                originContinuousTicks: 0, originAbsoluteTicks: 0,
                timebaseNumer: 1, timebaseDenom: 1, originWallTime: RFC3339.now()))
        manifest.schemaVersion = 99
        let encoder = JSONEncoder()
        let data = try encoder.encode(manifest)
        XCTAssertThrowsError(try Manifest.decode(from: data, path: "test")) { error in
            guard case ScreenreelError.schemaTooNew(let found, _, _) = error else {
                return XCTFail("expected schemaTooNew, got \(error)")
            }
            XCTAssertEqual(found, 99)
        }
    }

    func testUnsafeRelativePathsRejected() {
        XCTAssertTrue(Manifest.isSafeRelativePath("raw/screen/display-1-000001.mov"))
        XCTAssertFalse(Manifest.isSafeRelativePath("/etc/passwd"))
        XCTAssertFalse(Manifest.isSafeRelativePath("../outside.mov"))
        XCTAssertFalse(Manifest.isSafeRelativePath("raw/../../outside.mov"))
        XCTAssertFalse(Manifest.isSafeRelativePath(""))
    }

    func testAppendSegmentKeepsOrderAndDuration() {
        var manifest = Manifest(
            state: .recording,
            clock: ClockAnchor(
                originContinuousTicks: 0, originAbsoluteTicks: 0,
                timebaseNumer: 1, timebaseDenom: 1, originWallTime: RFC3339.now()))
        let track = TrackDescriptor(type: .screen, displayID: 1)
        manifest.tracks = [track]

        func segment(_ sequence: Int, endNs: Int64) -> SegmentDescriptor {
            SegmentDescriptor(
                trackID: track.id, trackType: .screen,
                path: "raw/screen/display-1-\(String(format: "%06d", sequence)).mov",
                sequenceInTrack: sequence, container: .mov, codec: .hevc,
                sourceStartNs: 0, sourceEndNs: endNs,
                normalizedStartNs: 0, normalizedEndNs: endNs,
                byteSize: 10, sha256: String(repeating: "0", count: 64),
                commitSequence: UInt64(sequence))
        }
        manifest.appendSegment(segment(2, endNs: 8_000_000_000))
        manifest.appendSegment(segment(1, endNs: 4_000_000_000))
        XCTAssertEqual(manifest.tracks[0].segments?.map(\.sequenceInTrack), [1, 2])
        XCTAssertEqual(manifest.durationNs, 8_000_000_000)
    }

    func testSessionLockRoundTripAndLiveness() throws {
        let url = directory.appendingPathComponent("session.lock")
        let lock = SessionLock(sessionID: UUID())
        try lock.write(to: url)
        let read = try SessionLock.read(from: url)
        XCTAssertEqual(read.sessionID, lock.sessionID)
        // The writing process is this test process, so the writer is alive.
        XCTAssertTrue(read.writerIsAlive())

        // A lock naming a dead (or reused) pid is not considered alive
        // because the start marker cannot match.
        var stale = lock
        stale.pid = 99999
        stale.processStartMarker = "99999:1.1"
        try stale.write(to: url)
        XCTAssertFalse(try SessionLock.read(from: url).writerIsAlive())
    }

    func testEventRecordRoundTripAndStructure() throws {
        let record = EventRecord(
            sequence: 7, timeNs: 123, type: .mouseDown,
            displayID: 1, xPx: 10.5, yPx: 20.0, cursorID: "arrow-1",
            button: .left, clickCount: 1, modifiers: [.command])
        let line = try record.jsonlLine()
        let parsed = try EventRecord.parse(line: Substring(line), lineNumber: 1)
        XCTAssertEqual(parsed, record)
        XCTAssertTrue(parsed.structuralProblems().isEmpty)
        XCTAssertEqual(parsed.chunkKind, .clicks)

        let broken = EventRecord(sequence: 8, timeNs: 124, type: .cursorMove)
        XCTAssertFalse(broken.structuralProblems().isEmpty)
    }
}
