// Generate public-safe demo content through Screen Reel's production capture
// and export engines. No screen, camera, microphone or user files are read.
// Run with Scripts/make-gallery.sh; output is rebuildable under .build/.
import AppKit
import CaptureCore
import CoreImage
import EventCapture
import ExportEngine
import Foundation
import PreviewEngine
import ProjectModel
import TimelineCore

private actor GallerySource: ScreenFrameSource {
    let artwork: CGImage
    private var task: Task<Void, Never>?
    init(artwork: CGImage) { self.artwork = artwork }
    func start(_ handler: @escaping @Sendable (VideoFrame) -> Void) async throws {
        task = Task {
            for index in 0..<240 {
                guard !Task.isCancelled else { break }
                autoreleasepool {
                    var output: CVPixelBuffer?
                    CVPixelBufferCreate(nil, 1920, 1080, kCVPixelFormatType_32BGRA,
                        [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &output)
                    guard let buffer = output else { return }
                    CVPixelBufferLockBaseAddress(buffer, [])
                    let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: 1920, height: 1080,
                        bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
                    context.draw(artwork, in: CGRect(x: 0, y: 0, width: 1920, height: 1080))
                    CVPixelBufferUnlockBaseAddress(buffer, [])
                    handler(VideoFrame(pixelBuffer: buffer, ptsNs: Int64(index) * 1_000_000_000 / 30))
                }
                try? await Task.sleep(for: .milliseconds(34))
            }
        }
    }
    func wait() async { await task?.value }
    func stop() async { task?.cancel(); await task?.value }
}

@main
struct Gallery {
    @MainActor static func artwork() -> CGImage {
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1920, pixelsHigh: 1080,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        defer { NSGraphicsContext.restoreGraphicsState() }
        func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> NSColor {
            NSColor(srgbRed: r, green: g, blue: b, alpha: 1)
        }
        let ink = color(0.17, 0.19, 0.16), muted = color(0.40, 0.44, 0.38)
        func text(_ value: String, _ x: CGFloat, _ y: CGFloat, _ size: CGFloat,
                  _ weight: NSFont.Weight = .regular, _ tint: NSColor? = nil) {
            (value as NSString).draw(at: NSPoint(x: x, y: 1080 - y - size * 1.2), withAttributes: [
                .font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: tint ?? ink])
        }
        func box(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ fill: NSColor, _ radius: CGFloat = 0) {
            fill.setFill()
            NSBezierPath(roundedRect: CGRect(x: x, y: 1080-y-h, width: w, height: h),
                         xRadius: radius, yRadius: radius).fill()
        }
        box(0, 0, 1920, 1080, color(0.985, 0.981, 0.959))
        box(0, 0, 1920, 74, color(0.938, 0.941, 0.912))
        text("FIELD NOTES", 80, 24, 19, .semibold)
        text("A small lesson in clarity", 785, 24, 20, .regular, muted)
        text("01 / 03", 1730, 24, 19, .medium, muted)
        text("THE ART OF EXPLAINING", 142, 170, 22, .semibold, muted)
        text("One clear idea.", 136, 223, 91, .medium)
        text("Give it room to become a story.", 142, 341, 33, .regular, muted)
        let labels = ["Idea", "Sketch", "Story"]
        let captions = ["Find the question.", "Make it visible.", "Let it connect."]
        for i in 0..<3 {
            let x = CGFloat(142 + i * 559)
            box(x, 491, 510, 249, i == 1 ? color(0.86, 0.89, 0.79) : color(0.939, 0.937, 0.900), 18)
            text("0\(i+1)", x+32, 519, 19, .medium, muted)
            text(labels[i], x+32, 559, 48, .medium)
            text(captions[i], x+32, 660, 23, .regular, muted)
            if i < 2 { text("→", x+519, 580, 30, .regular, muted) }
        }
        box(142, 878, 1636, 2, color(0.83, 0.85, 0.79))
        text("Show the detail. Let the rest fall away.", 142, 918, 27, .regular, muted)
        text("Screen Reel / demo content", 1430, 925, 20, .regular, muted)
        return bitmap.cgImage!
    }

    static func main() async throws {
        let directory = URL(fileURLWithPath: CommandLine.arguments[1])
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let project = directory.appendingPathComponent("A clear explanation.screenreel")
        let art = artwork()
        let source = GallerySource(artwork: art)
        let config = CaptureConfiguration(widthPx: 1920, heightPx: 1080, nominalFrameRate: 30,
            videoCodec: .hevc, displayID: 1, microphoneEnabled: true,
            microphoneDeviceName: "Generated demo tone", segmentDurationSeconds: 4)
        let session = CaptureSession(projectURL: project, configuration: config)
        let mic = SyntheticAudioSource(channels: 1, durationNs: 8_000_000_000, pace: 1)
        try await session.start(screen: source, microphone: mic, systemAudio: nil)
        let cursor = try await session.registerEventTrack(type: .cursorEvents)
        let clicks = try await session.registerEventTrack(type: .clickEvents)
        let layout = session.projectLayout()
        let events = EventChunkStore(layout: layout, trackIDs: [.cursor: cursor, .clicks: clicks],
            onCommit: { try await session.commitEventChunk($0) })
        var records: [EventRecord] = []
        for i in 0..<240 {
            let t = Double(i) / 30
            let x = t < 2 ? 340 + t * 300 : (t < 5 ? 940 : 940 + (t - 5) * 160)
            let y = 636 + 22 * sin(t * 1.4)
            let ns = Int64(i) * 1_000_000_000 / 30
            records.append(EventRecord(sequence: 0, timeNs: ns, type: .cursorMove,
                displayID: 1, xPx: x, yPx: y, buttons: 0))
            if i == 63 || i == 171 {
                records.append(EventRecord(sequence: 0, timeNs: ns, type: .mouseDown,
                    displayID: 1, xPx: x, yPx: y, button: .left, clickCount: 1))
                records.append(EventRecord(sequence: 0, timeNs: ns + 80_000_000, type: .mouseUp,
                    displayID: 1, xPx: x, yPx: y, button: .left, clickCount: 1))
            }
        }
        for record in records.sorted(by: { $0.timeNs < $1.timeNs }) { try await events.append(record) }
        try await events.finish()
        await source.wait()
        await mic.waitUntilFinished()
        let summary = try await session.stop()
        guard summary.videoFrames == 240, summary.droppedBuffers == 0, summary.validation.isHealthy else {
            fatalError("Demo capture lost frames: \(summary)")
        }
        let composition = try ProjectComposition(projectURL: project)
        try composition.updateEdits {
            $0.autoZoomEnabled = false
            $0.zooms = [ZoomSegment(startNs: 1_500_000_000, endNs: 5_000_000_000,
                                   scale: 1.85, focalX: 0.50, focalY: 0.57)]
            $0.style.background = .solid(.init(red: 0.79, green: 0.85, blue: 0.71))
            $0.style.padding = 0.08
            $0.style.cornerRadius = 0.025
            $0.cursor.sizeMultiplier = 1.8
        }
        func export(_ name: String) async throws {
            _ = try await StyledExporter.export(projectAt: project,
                to: directory.appendingPathComponent("\(name).mp4"), options: .init(
                    codec: .h264, outputHeight: 720, includeAudio: false))
        }
        try await export("zoom")
        let editorEdits = composition.edits
        try composition.updateEdits { $0.zooms = [] }
        try await export("cursor")
        let context = CIContext()
        composition.setOutputSize(SIMD2(1280, 720))
        let looks: [(String, Double, Double, Double)] = [
            ("sage", 0.79, 0.85, 0.71), ("clay", 0.83, 0.61, 0.48), ("ink", 0.23, 0.28, 0.25)]
        for (name, r, g, b) in looks {
            try composition.updateEdits { $0.style.background = .solid(.init(red: r, green: g, blue: b)) }
            let frame = try await composition.frame(atOutput: 0)!
            let cg = context.createCGImage(frame, from: frame.extent)!
            let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])!
            try png.write(to: directory.appendingPathComponent("style-\(name).png"))
        }
        try editorEdits.save(to: layout)
        print("Gallery project and exports: \(directory.path)")
    }
}
