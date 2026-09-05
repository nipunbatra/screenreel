import ArgumentParser
import CaptureCore
import Foundation
import ProjectModel

struct Selftest: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Record flash/beep markers through the real pipeline and MEASURE A/V sync.",
        discussion: """
            A synthetic screen source flashes white frames and a synthetic
            microphone beeps at the same capture times; both are recorded
            through the full clock → writer → container pipeline, decoded
            back, and paired. Reported: median A/V offset (audio-late
            positive), drift, and rejected outliers. Exit 0 when
            |median offset| < 40 ms and |drift| < 50 ms/min, exit 3 with the
            numbers otherwise. This mechanically verifies the whole
            capture-to-decode chain on this machine.
            """)

    @Option(help: "Recording duration in seconds (markers every 2 s).")
    var duration: Double = 10

    @Option(help: "Pacing: 1.0 = real time, 0 = as fast as possible.")
    var pace: Double = 1

    @Option(help: "Project path (default: a temporary package, removed on success).")
    var output: String?

    @Flag(help: "Keep the recorded project even when the selftest passes.")
    var keepProject = false

    @Flag(help: "Emit the full measurement report as JSON on stdout.")
    var json = false

    func run() async throws {
        guard duration >= 5 else {
            throw ValidationError("--duration must be at least 5 seconds (3+ markers)")
        }
        let durationNs = Int64(duration * 1_000_000_000)
        let temporary = output == nil
        let projectFile = output.map { projectURL(from: $0) }
            ?? FileManager.default.temporaryDirectory
                .appendingPathComponent("screenreel-selftest-\(UUID().uuidString).screenreel")

        if !json {
            let markers = SyncSelftest.markerTimesNs(durationNs: durationNs).count
            print("Recording \(String(format: "%.1f", duration)) s flash/beep session "
                + "(\(markers) markers, pace \(String(format: "%.1f", pace))) → \(projectFile.path)")
        }
        try await SyncSelftest.record(
            projectURL: projectFile, durationNs: durationNs, pace: pace,
            onWarning: { kind, message in
                FileHandle.standardError.write(Data("WARNING [\(kind)] \(message)\n".utf8))
            })
        let report = try await SyncSelftest.measure(projectAt: projectFile)

        if json {
            try Output.json(report)
        } else {
            print("Markers:  \(report.pairs) flash/beep pairs "
                + "(\(report.flashOnsets) flashes, \(report.beepOnsets) beeps, "
                + "\(report.outliersRejected) outlier(s) rejected)")
            print(String(
                format: "Offset:   %+.2f ms median (threshold |offset| < %.0f ms)",
                report.medianOffsetMs, report.offsetThresholdMs))
            print(String(
                format: "Drift:    %+.2f ms/min (threshold |drift| < %.0f ms/min)",
                report.driftMsPerMinute, report.driftThresholdMsPerMinute))
            print("RESULT:   \(report.passed ? "PASS" : "FAIL")")
        }

        if report.passed, temporary, !keepProject {
            try? FileManager.default.removeItem(at: projectFile)
        } else if !report.passed, !json {
            print("Project kept for inspection: \(projectFile.path)")
        }
        if !report.passed {
            throw ExitCode(3)
        }
    }
}
