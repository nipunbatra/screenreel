import AVFoundation
import XCTest

@testable import ExportEngine
@testable import PreviewEngine
@testable import ProjectModel

/// Export longevity gate + benchmark:
/// - env-gated long styled export with an exact frame-count assertion, an
///   A/V duration delta bound, and a peak-RSS log line;
/// - an always-on benchmark that styled-exports the standard 6 s fixture and
///   prints "export fps: N" so perf regressions are visible in CI logs.
///
/// Run the long gate explicitly (it renders that many minutes of video):
///   AKS_LONG_EXPORT_MINUTES=30 swift test --filter LongExportGateTests
final class LongExportGateTests: XCTestCase {
    private var directory: URL!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("aks-longexport-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    private static func peakRSSBytes() -> Int64 {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return Int64(usage.ru_maxrss)  // bytes on macOS
    }

    func testLongStyledExportGate() async throws {
        guard let minutesText = ProcessInfo.processInfo.environment["AKS_LONG_EXPORT_MINUTES"],
            let minutes = Int(minutesText), minutes > 0
        else {
            throw XCTSkip("set AKS_LONG_EXPORT_MINUTES=30 to run the long styled-export gate")
        }
        let durationNs = Int64(minutes) * 60_000_000_000
        // pace 4 (the factory default) keeps generation fast without
        // overflowing the audio handoff — flat-out (pace 0) delivery drops
        // mic chunks, which splinters the audio track into thousands of
        // gap segments and makes manifest commits quadratic.
        let projectURL = try await SyntheticProjectFactory.make(
            in: directory, durationNs: durationNs)

        let fps = 30.0
        let composition = try ProjectComposition(projectURL: projectURL)
        let range = composition.trimmedRange
        let expectedFrames = max(
            1, Int((Double(range.endNs - range.startNs) / 1e9 * fps).rounded(.up)))

        let outputURL = directory.appendingPathComponent("long.mp4")
        let started = Date()
        let result = try await StyledExporter.export(
            projectAt: projectURL,
            to: outputURL,
            options: .init(fps: fps, outputHeight: 180))
        let elapsed = Date().timeIntervalSince(started)

        // Exact frame count: any evaluation hole over the long haul fails.
        XCTAssertEqual(result.videoFrames, expectedFrames)

        // A/V track durations agree within 100 ms.
        let asset = AVURLAsset(
            url: outputURL, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let videoTrack = try await asset.loadTracks(withMediaType: .video).first
        let audioTrack = try await asset.loadTracks(withMediaType: .audio).first
        let videoDuration = try await XCTUnwrap(videoTrack).load(.timeRange).duration.seconds
        let audioDuration = try await XCTUnwrap(audioTrack).load(.timeRange).duration.seconds
        XCTAssertLessThan(
            abs(videoDuration - audioDuration), 0.100,
            "A/V track durations diverged: video \(videoDuration) s, audio \(audioDuration) s")

        let rssMB = Double(Self.peakRSSBytes()) / 1_048_576
        print(String(
            format: "long export gate: %d min, %d frames in %.1f s (%.1f fps), peak RSS %.0f MB",
            minutes, result.videoFrames, elapsed,
            Double(result.videoFrames) / max(elapsed, 0.001), rssMB))
    }

    /// Always-on styled-export benchmark on the standard 6 s fixture. No
    /// assertion beyond completion — the printed rate is the point.
    func testStyledExportBenchmarkPrintsExportFps() async throws {
        let projectURL = try await SyntheticProjectFactory.make(
            in: directory, durationNs: 6_000_000_000)
        let outputURL = directory.appendingPathComponent("benchmark.mp4")

        let started = Date()
        let result = try await StyledExporter.export(
            projectAt: projectURL,
            to: outputURL,
            options: .init(fps: 30, outputHeight: 180))
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertGreaterThan(result.videoFrames, 0)
        print(String(
            format: "export fps: %.1f (%d frames in %.2f s, 6 s fixture at 180p)",
            Double(result.videoFrames) / max(elapsed, 0.001),
            result.videoFrames, elapsed))
    }
}
