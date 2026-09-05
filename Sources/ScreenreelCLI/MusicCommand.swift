import ArgumentParser
import AudioPipeline
import Foundation
import ProjectModel
import TimelineCore

struct Music: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Import, adjust or remove a project's background music (styled exports).")
    @Argument var project: String
    @Option(help: "Music file to import into the project.") var file: String?
    @Option(help: "Music volume from 0 (muted) to 1 (full).") var volume: Double?
    @Flag(help: "Play once instead of looping.") var noLoop = false
    @Flag(help: "Loop the music to fill the video.") var loop = false
    @Flag(help: "Remove music from the edit; preserve imported files for undo.") var remove = false

    func validate() throws {
        if let volume, !volume.isFinite || !(0...1).contains(volume) { throw ValidationError("--volume must be between 0 and 1.") }
        guard !(loop && noLoop), !(remove && (file != nil || volume != nil || loop || noLoop)) else {
            throw ValidationError("Use --remove alone; choose either --loop or --no-loop.")
        }
    }
    func run() async throws {
        try validate()
        let layout = try ProjectPackage.load(at: projectURL(from: project)).layout
        var edits = try EditDocument.load(from: layout)
        if remove { edits.music = nil }
        else {
            if let file { edits.music = try MusicAsset.importFile(projectURL(from: file), into: layout) }
            guard edits.music != nil else { throw CLIError.failed("No music yet. Use --file song.mp3 to import it.") }
            if let volume { edits.music?.volume = volume }
            if noLoop { edits.music?.loops = false }
            if loop { edits.music?.loops = true }
        }
        try edits.save(to: layout)
        print(edits.music.map { "Music: \($0.name) · \(Int($0.gain * 100))% · \($0.loops ? "looping" : "play once")" } ?? "Music removed from the edit.")
    }
}
