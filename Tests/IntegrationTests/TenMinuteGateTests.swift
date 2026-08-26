import XCTest

@testable import CaptureCore
@testable import EventCapture
@testable import ProjectModel

/// The full Milestone 0 capture-integrity gate (ACCEPTANCE §2): ten minutes
/// of 4K30 with microphone and events, every committed segment independently
/// decodable, logical duration within one frame.
///
/// Run explicitly — it writes ~2 GB and takes several minutes:
///   AKS_RUN_LONG_TESTS=1 swift test --filter TenMinuteGateTests
final class TenMinuteGateTests: XCTestCase {
    func testTenMinute4K30CaptureGate() async throws {
        guard ProcessInfo.processInfo.environment["AKS_RUN_LONG_TESTS"] == "1" else {
            throw XCTSkip("set AKS_RUN_LONG_TESTS=1 to run the ten-minute 4K gate")
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("aks-10min-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let projectURL = directory.appendingPathComponent("tenminute.aks")

        let durationNs: Int64 = 600_000_000_000
        let pace: Double = 2  // 2× real time: ~5 minutes of wall clock
        let configuration = CaptureConfiguration(
            widthPx: 3840, heightPx: 2160, nominalFrameRate: 30,
            videoCodec: .hevc, displayID: 1,
            microphoneEnabled: true, microphoneDeviceName: "Synthetic Microphone",
            segmentDurationSeconds: 4)
        let session = CaptureSession(projectURL: projectURL, configuration: configuration)
        let screen = SyntheticScreenSource(
            width: 3840, height: 2160, frameRate: 30, durationNs: durationNs, pace: pace)
        let mic = SyntheticAudioSource(channels: 1, durationNs: durationNs, pace: pace)
        try await session.start(screen: screen, microphone: mic, systemAudio: nil)

        let cursorTrackID = try await session.registerEventTrack(type: .cursorEvents)
        let clickTrackID = try await session.registerEventTrack(type: .clickEvents)
        let store = EventChunkStore(
            layout: session.projectLayout(),
            trackIDs: [.cursor: cursorTrackID, .clicks: clickTrackID],
            onCommit: { [session] chunk in
                try await session.commitEventChunk(chunk)
            })
        let (stream, continuation) = AsyncStream.makeStream(of: EventRecord.self)
        let events = SyntheticEventSource(
            durationNs: durationNs, widthPx: 3840, heightPx: 2160, pace: pace)
        events.start { record in continuation.yield(record) }
        let pump = Task {
            for await record in stream {
                try? await store.append(record)
            }
            try? await store.finish()
        }

        await screen.waitUntilFinished()
        await mic.waitUntilFinished()
        await events.waitUntilFinished()
        continuation.finish()
        await pump.value
        let summary = try await session.stop()

        // Gate: nothing hidden, nothing lost.
        XCTAssertEqual(summary.videoFrames, 18_000)
        XCTAssertEqual(summary.droppedVideoFrames, 0)
        XCTAssertEqual(summary.droppedBuffers, 0)
        XCTAssertEqual(summary.micFrames, 48_000 * 600)
        XCTAssertTrue(summary.validation.isHealthy, "\(summary.validation.issues)")

        // Gate: join/logical duration within one frame.
        XCTAssertLessThanOrEqual(abs(summary.durationNs - durationNs), 33_333_334)

        // Gate: every committed segment opens independently and checksums
        // verify (deep validation probes each container).
        let report = await Validator(options: .init(
            verifyChecksums: true, mediaInspector: AVMediaInspector()))
            .validate(projectAt: projectURL)
        XCTAssertTrue(report.isHealthy, "\(report.issues)")
        let screenTrack = report.tracks.first { $0.type == .screen }
        XCTAssertEqual(screenTrack?.committedSegments, 150)  // 600 s / 4 s
    }
}
