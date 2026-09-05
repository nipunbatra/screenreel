import AppKit
import ArgumentParser
import CaptureCore
import Foundation

struct Screenshot: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Save a full-resolution PNG of a screen, window, app or area.")
    @Argument(help: "PNG file to create.") var output: String
    @OptionGroup var source: CaptureSourceOptions
    @Flag(help: "Replace an existing output file.") var overwrite = false

    func run() async throws {
        let url = projectURL(from: output)
        guard url.pathExtension.lowercased() == "png" else { throw ValidationError("Screenshot output must end in .png.") }
        if !overwrite, FileManager.default.fileExists(atPath: url.path) { throw CLIError.failed("Output exists; choose another filename or pass --overwrite.") }
        let configuration = try await source.resolve()
        let image = try await SCKCapture.screenshot(configuration: configuration)
        guard let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            throw CLIError.failed("Could not encode screenshot as PNG.")
        }
        try data.write(to: url, options: .atomic)
        print("Saved \(image.width)×\(image.height) PNG → \(url.path)")
    }
}
