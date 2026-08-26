import CoreImage
import Foundation
import ImageIO
import ProjectModel

/// Styled thumbnails for the project browser, cached under the package's
/// `derived/thumbnails/` (derived assets are rebuildable by definition —
/// deleting them never loses anything, `docs/PROJECT_FORMAT.md` §6).
public enum ProjectThumbnailer {

    public static func cacheURL(for projectURL: URL, height: Int) -> URL {
        ProjectLayout(root: projectURL)
            .derivedDirectory
            .appendingPathComponent("thumbnails")
            .appendingPathComponent("browser-h\(height).png")
    }

    /// Render (or load the cached) thumbnail. Any failure — unreadable
    /// project, damaged journal, undecodable media — returns nil rather than
    /// throwing: the browser shows a placeholder and `aks validate` explains.
    public static func thumbnail(for projectURL: URL, height: Int = 180) async -> CGImage? {
        let cache = cacheURL(for: projectURL, height: height)
        if let cached = loadPNG(at: cache) {
            return cached
        }
        guard let composition = try? ProjectComposition(
            projectURL: projectURL, previewDecodeMaxHeight: 360)
        else {
            return nil
        }
        let aspect = composition.edits.style.canvasAspect
            ?? (composition.sourceSize.x / composition.sourceSize.y)
        composition.setOutputSize(SIMD2(Double(height) * aspect, Double(height)))
        // A frame 10% in usually has real content on screen.
        // Probe in the OUTPUT domain so cuts, trim, and the camera intro
        // all show in the thumbnail exactly as they will in the export
        // (a fullscreen-intro project used to thumbnail as corner PiP).
        let range = composition.trimmedRange
        let probeNs = range.startNs + (range.endNs - range.startNs) / 10
        guard let image = try? await composition.frame(atOutput: probeNs) else {
            return nil
        }
        let context = CIContext()
        guard let cgImage = context.createCGImage(image, from: image.extent) else {
            return nil
        }
        writePNG(cgImage, to: cache)
        return cgImage
    }

    /// Drop the cache (thumbnails regenerate after edits change the look).
    public static func invalidate(for projectURL: URL) {
        let directory = ProjectLayout(root: projectURL)
            .derivedDirectory.appendingPathComponent("thumbnails")
        try? FileManager.default.removeItem(at: directory)
    }

    private static func loadPNG(at url: URL) -> CGImage? {
        guard let provider = CGDataProvider(url: url as CFURL),
            let image = CGImage(
                pngDataProviderSource: provider, decode: nil,
                shouldInterpolate: true, intent: .defaultIntent)
        else { return nil }
        return image
    }

    private static func writePNG(_ image: CGImage, to url: URL) {
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL, "public.png" as CFString, 1, nil)
        else { return }
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
    }
}
