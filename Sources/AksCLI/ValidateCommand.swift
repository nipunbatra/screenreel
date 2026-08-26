import ArgumentParser
import CaptureCore
import Foundation
import ProjectModel

struct Validate: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Validate a project: journal chain, committed assets, checksums, decodability.")

    @Argument(help: "Path to the .aks project package.")
    var project: String

    @Flag(help: "Skip SHA-256 verification of committed assets.")
    var fast = false

    @Flag(help: "Skip media container probing.")
    var noProbe = false

    @Flag(help: "Emit the full report as JSON.")
    var json = false

    func run() async throws {
        let validator = Validator(options: .init(
            verifyChecksums: !fast,
            mediaInspector: noProbe ? nil : AVMediaInspector()))
        let report = await validator.validate(projectAt: projectURL(from: project))

        if json {
            try Output.json(report)
        } else {
            printHuman(report)
        }
        if !report.isHealthy {
            throw ExitCode(1)
        }
    }

    private func printHuman(_ report: ValidationReport) {
        print("Project:  \(report.projectPath)")
        print("State:    \(report.state?.rawValue ?? "unknown") (manifest generation \(report.manifestGeneration.map(String.init) ?? "-"))")
        var journalLine = "Journal:  \(report.journalRecordCount) trusted records"
        if let reason = report.journalTruncationReason {
            journalLine += ", TRUNCATED at line \(report.journalTruncatedAtLine ?? 0): \(reason)"
        } else {
            journalLine += report.journalFinalized ? ", finalized" : ", not finalized"
        }
        print(journalLine)
        for track in report.tracks {
            let assets = track.type.isMedia
                ? "\(track.committedSegments) segments"
                : "\(track.committedChunks) chunks"
            print("Track:    \(track.type.rawValue): \(assets), \(Output.bytes(track.committedBytes)), covers \(Output.duration(ns: track.coverageEndNs))")
        }
        if !report.orphanCandidates.isEmpty {
            print("Orphans:  \(report.orphanCandidates.count) finalized file(s) without journal records")
        }
        if !report.partialTails.isEmpty {
            print("Partials: \(report.partialTails.count) interrupted write(s)")
        }
        for issue in report.issues {
            let tag = issue.severity.rawValue.uppercased().padding(toLength: 7, withPad: " ", startingAt: 0)
            print("\(tag) [\(issue.code)] \(issue.message)\(issue.path.map { " (\($0))" } ?? "")")
        }
        print(report.isHealthy ? "RESULT: healthy" : "RESULT: PROBLEMS FOUND")
        if report.needsRecovery {
            print("Recovery recommended: aks recover \"\(report.projectPath)\"")
        }
    }
}
