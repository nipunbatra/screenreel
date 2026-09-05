import CoreImage
import Foundation
import ImageIO
import PreviewEngine
import ProjectModel
import UniformTypeIdentifiers

/// Animated-GIF export through the SAME composition graph as MP4 export:
/// cuts, speeds, trim, zooms, cursor, camera, and styling all evaluate
/// identically — only the container and palette differ. The output appears
/// atomically (temp file + rename); a cancelled export leaves nothing
/// behind and the project untouched.
public enum GIFExporter {

    public struct Options: Sendable {
        /// GIF frame rate. Decoders clamp aggressively below 50ms/frame,
        /// so rates above 20 mostly waste bytes.
        public var fps: Double = 12
        /// Output height cap in pixels; width follows the canvas aspect.
        public var maxHeight: Int = 540
        public var overwrite: Bool = false

        public init(fps: Double = 12, maxHeight: Int = 540, overwrite: Bool = false) {
            self.fps = fps
            self.maxHeight = maxHeight
            self.overwrite = overwrite
        }
    }

    public struct Summary: Sendable {
        public let frames: Int
        public let width: Int
        public let height: Int
        public let byteSize: Int64
    }

    public static func export(
        projectURL: URL,
        to outputURL: URL,
        options: Options = Options(),
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> Summary {
        let fm = FileManager.default
        if fm.fileExists(atPath: outputURL.path), !options.overwrite {
            throw ScreenreelError.ioFailed(
                operation: "gif export", path: outputURL.path, errno: EEXIST)
        }

        let activity = SystemActivity(.export, reason: "GIF export")
        defer { activity.end() }
        guard options.fps > 0, options.fps <= 50 else {
            throw ScreenreelError.invariantViolated("gif fps must be in (0, 50]")
        }

        // Decode at a modest proxy: geometry is resolution-independent and
        // the palette destroys detail long before the proxy does.
        let composition = try ProjectComposition(
            projectURL: projectURL,
            previewDecodeMaxHeight: max(options.maxHeight, 360) * 3 / 2)
        let range = composition.trimmedRange
        let rangeDurationNs = range.endNs - range.startNs
        guard rangeDurationNs > 0 else {
            throw ScreenreelError.invariantViolated("trimmed range is empty")
        }

        // Canvas geometry mirrors StyledExporter: aspect from the edit
        // document's reframe, height capped for GIF economics.
        let sourceSize = composition.sourceSize
        let aspect = composition.edits.style.canvasAspect
            ?? (sourceSize.x / sourceSize.y)
        let height = Double(min(options.maxHeight, Int(sourceSize.y.rounded())))
        let width = (height * aspect).rounded()
        composition.setOutputSize(SIMD2(width, height))

        // Epsilon-tolerant ceil: 280 ms × 25 fps computes as 7.0000…01 in
        // Double and must not become 8 frames.
        let exactFrames = Double(rangeDurationNs) / 1e9 * options.fps
        let totalFrames = max(1, Int((exactFrames - 1e-6).rounded(.up)))

        // ImageIO buffers EVERY appended frame until finalize (measured:
        // ~3 GB for 530 frames at 540p), so long ranges must refuse up
        // front with a way out — not OOM the machine mid-export.
        let pixelBudget = 600_000_000.0
        let projectedPixels = Double(totalFrames) * width * height
        guard projectedPixels <= pixelBudget else {
            let maxSeconds = pixelBudget / (width * height * options.fps)
            throw ScreenreelError.invariantViolated(String(
                format: "GIF export is for short clips: this range renders "
                    + "%d frames at %.0f×%.0f (too much to hold in memory). "
                    + "Trim or cut the range to ≤%.0f s, lower --height, or "
                    + "lower --fps.",
                totalFrames, width, height, maxSeconds))
        }
        let delay = 1.0 / options.fps

        let tempURL = outputURL.deletingLastPathComponent()
            .appendingPathComponent(".gif-export-\(UUID().uuidString).tmp")
        defer { try? fm.removeItem(at: tempURL) }

        guard let destination = CGImageDestinationCreateWithURL(
            tempURL as CFURL, UTType.gif.identifier as CFString,
            totalFrames, nil)
        else {
            throw ScreenreelError.ioFailed(
                operation: "gif create", path: tempURL.path, errno: EIO)
        }
        // Loop forever — the only sane default for a screen-demo GIF.
        CGImageDestinationSetProperties(destination, [
            kCGImagePropertyGIFDictionary: [
                kCGImagePropertyGIFLoopCount: 0
            ]
        ] as CFDictionary)

        let context = CIContext(options: [.cacheIntermediates: false])
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        let frameProperties = [
            kCGImagePropertyGIFDictionary: [
                kCGImagePropertyGIFDelayTime: delay,
                kCGImagePropertyGIFUnclampedDelayTime: delay,
            ]
        ] as CFDictionary

        var appendedFrames = 0
        for frameIndex in 0..<totalFrames {
            try Task.checkCancellation()
            let outputNs = Int64(Double(frameIndex) / options.fps * 1e9)
            let timelineNs = min(range.startNs + outputNs, range.endNs - 1)
            guard let composed = try await composition.frame(atOutput: timelineNs)
            else { continue }
            guard let cgImage = context.createCGImage(
                composed, from: composed.extent,
                format: .RGBA8, colorSpace: colorSpace)
            else {
                throw ScreenreelError.invariantViolated(
                    "gif frame \(frameIndex) failed to rasterize")
            }
            CGImageDestinationAddImage(destination, cgImage, frameProperties)
            appendedFrames += 1
            if frameIndex % 10 == 0 {
                progress?(Double(frameIndex) / Double(totalFrames))
            }
        }
        guard appendedFrames > 0 else {
            throw ScreenreelError.invariantViolated("no frames could be rendered")
        }

        // A cancellation that lands during the last frame must not publish.
        try Task.checkCancellation()
        guard CGImageDestinationFinalize(destination) else {
            throw ScreenreelError.ioFailed(
                operation: "gif finalize", path: tempURL.path, errno: EIO)
        }
        if fm.fileExists(atPath: outputURL.path) {
            _ = try fm.replaceItemAt(outputURL, withItemAt: tempURL)
        } else {
            try fm.moveItem(at: tempURL, to: outputURL)
        }
        progress?(1)

        let bytes = (try? fm.attributesOfItem(atPath: outputURL.path))?[.size]
            as? Int64 ?? 0
        return Summary(
            frames: appendedFrames, width: Int(width), height: Int(height),
            byteSize: bytes)
    }
}
