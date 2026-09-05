import ArgumentParser
import ExportEngine
import Foundation
import ProjectModel

struct Export: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Assemble a project's raw segments into one playable MP4.",
        discussion: """
            Video is stream-copied from the committed segments (no re-encode,
            no quality loss); microphone and system audio are mixed and
            AAC-encoded; recording gaps become explicit silence. Raw media is
            never modified, and the output appears only after it validates.
            Add --styled to apply saved cursor, zoom, background, camera and
            audio-cleanup edits. Add --checkpoint for resumable rendering.
            A .gif output path
            renders a looping animated GIF through the styled composition
            graph instead (use --height/--fps to tune size).
            """)

    @Argument(help: "Path to the .screenreel project package.")
    var project: String

    @Argument(help: "Output MP4 path (default: '<project name>.mp4' next to the project).")
    var output: String?

    @Flag(help: "Export video only, no audio track.")
    var noAudio = false

    @Option(help: "AAC audio bitrate in bits per second.")
    var audioBitrate = 160_000

    @Flag(help: "Replace the output file if it exists.")
    var force = false

    @Flag(help: "Render with the project's edits: background, padding, corners, shadow, smoothed cursor, auto zooms (re-encodes).")
    var styled = false

    @Option(help: "Styled export output height in pixels (default: source height).")
    var height: Int?

    @Option(help: "Styled export frame rate.")
    var fps: Double = 30

    @Flag(help: "Resumable styled export: renders in checkpointed segments under the project's jobs/ directory; re-running after a crash or Ctrl-C resumes at the first missing segment. Implies --styled.")
    var checkpoint = false

    func run() async throws {
        let projectFile = projectURL(from: project)
        let outputFile = output.map { projectURL(from: $0) }
            ?? projectFile.deletingPathExtension().appendingPathExtension("mp4")

        // Refuse obviously unsafe destinations inside the package.
        if outputFile.path.hasPrefix(projectFile.path + "/") {
            throw ValidationError("output must not be inside the project package")
        }

        // Preflight: every committed media segment must exist before any
        // writer starts, so a deleted or moved file fails fast with the
        // exact relative path and a recovery action instead of surfacing as
        // an opaque decoder error mid-export.
        let loaded = try ProjectPackage.load(at: projectFile)
        for track in loaded.manifest.tracks {
            for segment in track.segments ?? [] {
                let segmentURL = try loaded.layout.resolve(relativePath: segment.path)
                guard FileManager.default.fileExists(atPath: segmentURL.path) else {
                    throw CLIError.failed(
                        "export preflight failed: referenced asset is missing: \(segment.path) "
                            + "(track \(track.type.rawValue), segment #\(segment.sequenceInTrack)). "
                            + "Raw media is never touched by export; run `screenreel validate` for the "
                            + "full picture and `screenreel recover` to rebuild a consistent copy.")
                }
            }
        }

        // A .gif destination routes to the GIF exporter: same composition
        // graph as styled MP4, palette container instead of H.264.
        if outputFile.pathExtension.lowercased() == "gif" {
            print("Exporting \(projectFile.lastPathComponent) → \(outputFile.path) (animated GIF)")
            let gifStarted = Date()
            let gifProgress: @Sendable (Double) -> Void = { fraction in
                let percent = Int(fraction * 100)
                FileHandle.standardError.write(Data("\rGIF: \(percent)%   ".utf8))
            }
            let summary = try await GIFExporter.export(
                projectURL: projectFile,
                to: outputFile,
                options: .init(
                    fps: min(fps, 20),
                    maxHeight: height ?? 540,
                    overwrite: force),
                progress: gifProgress)
            FileHandle.standardError.write(Data("\r".utf8))
            let elapsed = Date().timeIntervalSince(gifStarted)
            print("Wrote \(summary.frames) frames at \(summary.width)×\(summary.height), "
                + "\(ByteCountFormatter.string(fromByteCount: summary.byteSize, countStyle: .file)) "
                + String(format: "in %.1fs.", elapsed))
            return
        }

        print("Exporting \(projectFile.lastPathComponent) → \(outputFile.path)"
            + (styled ? " (styled)" : " (raw assembly)"))
        let started = Date()
        let progressPrinter: @Sendable (String, Double) -> Void = { stage, fraction in
            let percent = Int(fraction * 100)
            FileHandle.standardError.write(Data("\r\(stage): \(percent)%   ".utf8))
        }

        if checkpoint {
            let checkpointStarted = Date()
            let checkpointProgress: @Sendable (String, Double) -> Void = { stage, fraction in
                let percent = Int(fraction * 100)
                FileHandle.standardError.write(Data("\r\(stage): \(percent)%   ".utf8))
            }
            let result = try await CheckpointedExporter.export(
                projectAt: projectFile, to: outputFile,
                options: .init(
                    fps: fps,
                    outputHeight: height,
                    includeAudio: !noAudio,
                    aacBitrate: audioBitrate,
                    overwrite: force,
                    progress: checkpointProgress))
            FileHandle.standardError.write(Data("\r".utf8))
            let elapsed = Date().timeIntervalSince(checkpointStarted)
            print(String(
                format: "Done in %.1f s: %d frames (%d segments rendered, %d reused).",
                elapsed, result.videoFrames,
                result.segmentsRendered, result.segmentsReused))
            for warning in Set(result.warnings) { print("warning: \(warning)") }
            return
        }

        let durationNs: Int64
        let summaryLines: [String]
        var warnings: [String]
        if styled {
            let result = try await StyledExporter.export(
                projectAt: projectFile,
                to: outputFile,
                options: .init(
                    fps: fps,
                    outputHeight: height,
                    includeAudio: !noAudio,
                    aacBitrate: audioBitrate,
                    overwrite: force,
                    progress: progressPrinter))
            durationNs = result.durationNs
            warnings = result.warnings
            summaryLines = [
                "Video:    \(result.videoFrames) styled frames rendered",
                result.audioFrames > 0 ? "Audio:    \(result.audioFrames) frames AAC" : "",
            ]
        } else {
            let result = try await SegmentAssembler.assemble(
                projectAt: projectFile,
                to: outputFile,
                options: .init(
                    includeAudio: !noAudio,
                    aacBitrate: audioBitrate,
                    overwrite: force,
                    progress: progressPrinter))
            durationNs = result.durationNs
            warnings = result.warnings
            let silence = Double(result.silenceFramesInserted) / 48_000
            summaryLines = [
                "Video:    \(result.videoFrames) frames from \(result.videoSegments) segments (stream copy)",
                result.audioFrames > 0
                    ? "Audio:    \(result.audioFrames) frames AAC"
                        + (silence > 0.05 ? String(format: " (%.1f s gap silence inserted)", silence) : "")
                    : "",
            ]
        }
        FileHandle.standardError.write(Data("\r".utf8))

        let elapsed = Date().timeIntervalSince(started)
        let speed = Double(durationNs) / 1e9 / max(elapsed, 0.001)
        print("Done in \(String(format: "%.1f", elapsed)) s (\(String(format: "%.1f", speed))× real time).")
        print("Output:   \(outputFile.path)")
        print("Duration: \(Output.duration(ns: durationNs))")
        for line in summaryLines where !line.isEmpty {
            print(line)
        }
        for warning in warnings {
            print("WARNING:  \(warning)")
        }
    }
}
