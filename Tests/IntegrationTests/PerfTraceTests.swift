import XCTest

@testable import CaptureCore
@testable import Diagnostics
@testable import ProjectModel

/// Every recording leaves a per-second performance trace and a digest so
/// "the app was laggy" is answerable from the project itself.
final class PerfTraceTests: XCTestCase {
    private var directory: URL!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("screenreel-perf-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    func testSessionWritesPerfTraceAndSummary() async throws {
        let projectURL = directory.appendingPathComponent("perf.screenreel")
        let configuration = CaptureConfiguration(
            widthPx: 320, heightPx: 180, nominalFrameRate: 30,
            videoCodec: .hevc, displayID: 1,
            microphoneEnabled: true, microphoneDeviceName: "Synthetic Microphone",
            segmentDurationSeconds: 2)
        let session = CaptureSession(projectURL: projectURL, configuration: configuration)
        let durationNs: Int64 = 2_400_000_000
        let screen = SyntheticScreenSource(
            width: 320, height: 180, frameRate: 30, durationNs: durationNs, pace: 1)
        let mic = SyntheticAudioSource(channels: 1, durationNs: durationNs, pace: 1)
        await session.setPerfProbe {
            ["tapMaxCallbackUs": .integer(250), "tapReenables": .integer(0)]
        }
        try await session.start(screen: screen, microphone: mic, systemAudio: nil)
        // Two heartbeats land in 2.4 s of real-time pacing.
        await screen.waitUntilFinished()
        await mic.waitUntilFinished()
        let summary = try await session.stop()

        let perf = try XCTUnwrap(summary.perf)
        XCTAssertGreaterThanOrEqual(perf.samples, 3, "baseline + heartbeats + stop")
        XCTAssertGreaterThan(perf.durationNs, 2_000_000_000)
        XCTAssertGreaterThan(perf.peakResidentBytes, 0)
        XCTAssertEqual(perf.counters["videoFrames"]?.integerValue, Int64(summary.videoFrames))
        XCTAssertEqual(perf.counters["tapMaxCallbackUs"]?.integerValue, 250)
        XCTAssertFalse(perf.headline.isEmpty)

        let layout = ProjectLayout(root: projectURL)
        let traceURL = layout.diagnosticsDirectory.appendingPathComponent("perf.jsonl")
        let trace = try String(contentsOf: traceURL, encoding: .utf8)
        let lines = trace.split(separator: "\n")
        XCTAssertGreaterThanOrEqual(lines.count, 2, trace)
        for line in lines {
            let object = try JSONDecoder().decode(JSONValue.self, from: Data(line.utf8))
            XCTAssertEqual(object["event"]?.stringValue, "perf")
            XCTAssertNotNil(object["processCPUPercent"]?.doubleValue, String(line))
            XCTAssertNotNil(object["videoFrames"]?.integerValue, String(line))
            XCTAssertEqual(object["tapMaxCallbackUs"]?.integerValue, 250)
        }

        let summaryURL = layout.diagnosticsDirectory.appendingPathComponent("perf-summary.json")
        let decoded = try JSONDecoder().decode(
            PerfSummary.self, from: Data(contentsOf: summaryURL))
        XCTAssertEqual(decoded, perf)

        // The trace is diagnostics, never part of validation's media set.
        XCTAssertTrue(summary.validation.isHealthy, "\(summary.validation.issues)")
    }
}
