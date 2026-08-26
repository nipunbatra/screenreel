import ArgumentParser
import CaptureCore
import Foundation
import ProjectModel

struct Recover: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Produce a recovered copy of an interrupted or damaged project.",
        discussion: """
            The original package is never modified. Committed data is verified
            (size, SHA-256, decodability) and cloned into a new package whose
            manifest and journal are rebuilt; interrupted .partial writes are
            quarantined, never deleted.
            """)

    @Argument(help: "Path to the .aks project package.")
    var project: String

    @Option(help: "Destination for the recovered package (default: sibling '<name> Recovered <time>.aks').")
    var output: String?

    @Flag(help: "Attach valid, contiguous, unjournaled tail segments after inspection.")
    var attachOrphans = false

    @Flag(help: "Emit the recovery report as JSON.")
    var json = false

    func run() async throws {
        let options = RecoveryOptions(
            attachOrphans: attachOrphans,
            mediaInspector: AVMediaInspector(),
            destination: output.map { projectURL(from: $0) })
        let report = try await Recovery.recover(
            projectAt: projectURL(from: project), options: options)

        if json {
            try Output.json(report)
        } else {
            print("Recovered copy: \(report.recoveredPath)")
            print("Trusted journal records: \(report.journalTrustedRecords)"
                + (report.journalTruncationReason.map { " (journal truncated: \($0))" } ?? ""))
            print("Recovered: \(report.recoveredSegments) segments, \(report.recoveredChunks) event chunks, "
                + "duration \(Output.duration(ns: report.rebuiltDurationNs))")
            if !report.rejectedAssets.isEmpty {
                print("Rejected (failed verification): \(report.rejectedAssets.joined(separator: ", "))")
            }
            if !report.attachedOrphans.isEmpty {
                print("Attached orphans: \(report.attachedOrphans.joined(separator: ", "))")
            }
            if !report.unattachedOrphans.isEmpty {
                print("Unattached orphans preserved: \(report.unattachedOrphans.joined(separator: ", "))")
            }
            if !report.quarantinedPartials.isEmpty {
                print("Quarantined partials: \(report.quarantinedPartials.joined(separator: ", "))")
            }
            for issue in report.issues {
                print("\(issue.severity.rawValue.uppercased()) [\(issue.code)] \(issue.message)\(issue.path.map { " (\($0))" } ?? "")")
            }
            print("Original package untouched. Open the recovered copy to continue.")
        }
    }
}
