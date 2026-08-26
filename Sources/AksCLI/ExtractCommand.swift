import ArgumentParser
import Foundation
import ProjectModel

struct Extract: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Copy raw media and an events CSV/JSON export out of a project.",
        discussion: """
            Works even when the manifest or journal cannot be loaded — this is
            the raw extraction guarantee (docs/PROJECT_FORMAT.md §9). Ordinary
            tools (QuickTime, ffprobe, ffmpeg) can open every extracted file.
            """)

    @Argument(help: "Path to the .aks project package.")
    var project: String

    @Argument(help: "Destination directory for the extracted assets.")
    var destination: String

    @Flag(help: "Hard-link instead of cloning/copying (same volume only).")
    var link = false

    func run() async throws {
        let report = try await Extractor.extract(
            projectAt: projectURL(from: project),
            to: projectURL(from: destination),
            useHardLinks: link)
        print("Extracted to: \(report.destinationPath)")
        print("Media files: \(report.mediaFiles.count)")
        print("Event exports: \(report.eventExports.joined(separator: ", "))")
        print("Cursor descriptors: \(report.cursorDescriptors)")
        for issue in report.issues {
            print("\(issue.severity.rawValue.uppercased()) [\(issue.code)] \(issue.message)\(issue.path.map { " (\($0))" } ?? "")")
        }
        if report.issues.contains(where: { $0.severity == .error }) {
            throw ExitCode(1)
        }
    }
}
