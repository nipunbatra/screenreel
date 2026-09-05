// Production exports of ACTUAL window captures. Never generates recording pixels/events.
import AppKit
import AudioPipeline
import CoreImage
import ExportEngine
import Foundation
import PreviewEngine
import ProjectModel
import TimelineCore

@main struct ExportRealGallery {
    static func main() async throws {
        let directory = URL(fileURLWithPath: CommandLine.arguments[1])
        let project = directory.appendingPathComponent("Silent window.screenreel")
        let voiceProject = directory.appendingPathComponent("Voice comparison.screenreel")
        func style(_ composition: ProjectComposition) throws {
            try composition.updateEdits {
                $0.autoZoomEnabled = false
                $0.zooms = []
                $0.style.canvasAspect = 16.0 / 9
                $0.style.background = .solid(.init(red: 0.79, green: 0.85, blue: 0.71))
                $0.style.padding = 0.065
                $0.style.cornerRadius = 0.02
                $0.trimStartNs = 0
                $0.trimEndNs = 12_000_000_000
            }
        }
        func export(_ source: URL, _ name: String, audio: Bool) async throws {
            let result = try await StyledExporter.export(projectAt: source,
                to: directory.appendingPathComponent(name + ".mp4"),
                options: .init(codec: .h264, outputHeight: 720, includeAudio: audio, overwrite: true))
            guard result.videoFrames == 360 else { throw ScreenreelError.invariantViolated("Expected a 12-second export") }
            print("\(name): \(result.videoFrames) video frames, \(result.audioFrames) audio frames")
        }
        let composition = try ProjectComposition(projectURL: project)
        try style(composition)
        try composition.updateEdits { $0.music = nil }
        try await export(project, "window", audio: false)
        let music = try MusicAsset.importFile(directory.appendingPathComponent("demo-music.wav"), into: composition.layout)
        try composition.updateEdits { $0.music = music; $0.music?.volume = 0.65 }
        try await export(project, "music", audio: true)
        try composition.updateEdits {
            $0.music = nil
            $0.zooms = [.init(startNs: 2_000_000_000, endNs: 8_000_000_000, scale: 1.65, focalX: 0.50, focalY: 0.53)]
        }
        try await export(project, "zoom", audio: false)
        let editorEdits = composition.edits
        let context = CIContext()
        composition.setOutputSize(SIMD2(1280, 720))
        for (name, color) in [("sage", (0.79,0.85,0.71)), ("clay", (0.83,0.61,0.48)), ("ink", (0.23,0.28,0.25))] {
            try composition.updateEdits {
                $0.zooms = []
                $0.style.background = .solid(.init(red: color.0, green: color.1, blue: color.2))
            }
            let frame = try await composition.frame(atOutput: 1_000_000_000)!
            let image = context.createCGImage(frame, from: frame.extent)!
            try NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!
                .write(to: directory.appendingPathComponent("style-\(name).png"))
        }
        try editorEdits.save(to: composition.layout)
        let voice = try ProjectComposition(projectURL: voiceProject)
        try style(voice)
        try voice.updateEdits { $0.micNoiseReduction = false }
        try await export(voiceProject, "voice-original", audio: true)
        try voice.updateEdits { $0.micNoiseReduction = true }
        try await export(voiceProject, "voice-clean", audio: true)
    }
}
