import ArgumentParser
import Captions
import Foundation
import ProjectModel
import TimelineCore

struct CaptionsExport: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "captions",
        abstract: "Write a project's captions as SRT or WebVTT.",
        discussion: """
            Serializes the caption cues transcribed in the editor (stored in
            edits/captions.json) with the project's cuts, speed changes, and
            trim applied — the timestamps line up with a styled export of the
            same project. Purely file-based: no permissions, no re-encode,
            raw media untouched. Transcribe once in the editor first
            (Captions → Transcribe).
            """)

    @Argument(help: "Path to the .screenreel project package.")
    var project: String

    @Argument(help: "Output path (default: '<project name>.srt'/'.vtt' next to the project).")
    var output: String?

    @Option(help: "Subtitle format: srt or vtt.")
    var format: String = "srt"

    @Flag(help: "Emit raw source-time cues, ignoring cuts, speeds, and trim.")
    var sourceTime = false

    func run() async throws {
        guard let captionFormat = CaptionFormat(rawValue: format.lowercased()) else {
            throw CLIError.failed(
                "Unknown format '\(format)'. Use one of: "
                    + CaptionFormat.allCases.map(\.rawValue).joined(separator: ", "))
        }
        let projectRoot = projectURL(from: project)
        let layout = ProjectLayout(root: projectRoot)
        let cues = try CaptionStore.load(from: layout)
        guard !cues.isEmpty else {
            throw CLIError.failed(
                "No captions in \(projectRoot.lastPathComponent). "
                    + "Open it in the editor and run Captions → Transcribe first.")
        }

        let mapped: [CaptionCue]
        if sourceTime {
            mapped = cues
        } else {
            let loaded = try ProjectPackage.load(at: projectRoot)
            let edits = try EditDocument.load(from: layout)
            let timeline = ClipTimeline(
                clips: edits.clips,
                sourceDurationNs: loaded.manifest.durationNs ?? 0)
            let total = timeline.outputDurationNs
            let start = max(0, edits.trimStartNs ?? 0)
            let end = min(total, edits.trimEndNs ?? total)
            mapped = CaptionWriter.clipped(
                CaptionWriter.remapped(cues, through: timeline),
                toRange: (min(start, end), max(start, end)))
        }
        guard !mapped.isEmpty else {
            throw CLIError.failed(
                "All \(cues.count) cues fall outside the edited range; nothing to write.")
        }

        let outputURL = output.map { URL(fileURLWithPath: $0) }
            ?? projectRoot.deletingPathExtension()
                .appendingPathExtension(captionFormat.rawValue)
        let text = CaptionWriter.serialize(mapped, format: captionFormat)
        try Data(text.utf8).write(to: outputURL, options: .atomic)
        print("Wrote \(mapped.count) cue\(mapped.count == 1 ? "" : "s") to \(outputURL.path)")
    }
}
