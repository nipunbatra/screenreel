import XCTest

@testable import CaptureCore
@testable import ProjectModel

/// Two stops racing (the pill and the menu item, or an operator stop
/// during the disk-full self-stop) must both get the same finished summary
/// — never "stop() called twice" bubbling up as "Stop failed".
final class StopRaceTests: XCTestCase {
    private var directory: URL!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("screenreel-stoprace-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    func testConcurrentStopsShareOneResult() async throws {
        let projectURL = directory.appendingPathComponent("race.screenreel")
        let configuration = CaptureConfiguration(
            widthPx: 320, heightPx: 180, nominalFrameRate: 30,
            videoCodec: .hevc, displayID: 1,
            microphoneEnabled: true, microphoneDeviceName: "Synthetic Microphone",
            segmentDurationSeconds: 4)
        let session = CaptureSession(projectURL: projectURL, configuration: configuration)
        let screen = SyntheticScreenSource(
            width: 320, height: 180, frameRate: 30, durationNs: 20_000_000_000, pace: 1)
        let mic = SyntheticAudioSource(channels: 1, durationNs: 20_000_000_000, pace: 1)
        try await session.start(screen: screen, microphone: mic, systemAudio: nil)
        try await Task.sleep(for: .milliseconds(700))

        async let first = session.stop()
        async let second = session.stop()
        let (a, b) = try await (first, second)
        XCTAssertEqual(a.videoFrames, b.videoFrames)
        XCTAssertEqual(a.durationNs, b.durationNs)
        XCTAssertGreaterThan(a.videoFrames, 0)
        XCTAssertTrue(a.validation.isHealthy, "\(a.validation.issues)")

        // Late event chunks are refused instead of landing after
        // sessionFinalized.
        let trackID = UUID()
        let chunk = EventChunkDescriptor(
            trackID: trackID, kind: .cursor, path: "events/cursor-000009.jsonl",
            sequenceInTrack: 9, firstEventSequence: 1, lastEventSequence: 1,
            startNs: 0, endNs: 1, recordCount: 1, byteSize: 1,
            sha256: String(repeating: "0", count: 64), commitSequence: 0)
        do {
            try await session.commitEventChunk(chunk)
            XCTFail("commit after stop must be refused")
        } catch {
            XCTAssertTrue("\(error)".contains("stopping"), "\(error)")
        }
        let loaded = try ProjectPackage.load(at: projectURL)
        XCTAssertTrue(loaded.journal.isFinalized)
    }
}
