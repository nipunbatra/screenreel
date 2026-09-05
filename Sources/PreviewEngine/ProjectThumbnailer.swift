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

    /// One shared render context: creating a CIContext spins up a Metal
    /// device and shader caches (~100 ms and tens of MB), which the old
    /// per-thumbnail context paid for every card on every launch.
    private static let renderContext = CIContext()

    /// A failed render is remembered next to where the PNG would be, keyed
    /// by the project's modification stamp: a damaged project used to be
    /// re-parsed (journal + media probe) on every app launch and every
    /// browser refresh, forever.
    public static func failureMarkerURL(for projectURL: URL, height: Int) -> URL {
        cacheURL(for: projectURL, height: height)
            .deletingPathExtension().appendingPathExtension("failed")
    }

    /// Newest modification time among the files whose change could turn a
    /// failure into a success (recovery rewrites the journal, edits change
    /// the look, the package itself gains or loses entries).
    private static func modificationStamp(of projectURL: URL) -> String {
        let layout = ProjectLayout(root: projectURL)
        // Raw media directories: replacing a segment in place (a repair)
        // touches the directory's mtime, so it must retry too.
        let candidates = [
            projectURL, layout.manifestURL, layout.journalURL, layout.editsDirectory,
            layout.screenDirectory, layout.cameraDirectory, layout.microphoneDirectory,
            layout.systemAudioDirectory,
        ]
        let newest = candidates.compactMap {
            (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate
        }.max() ?? .distantPast
        return String(newest.timeIntervalSince1970)
    }

    /// Render (or load the cached) thumbnail. Any failure — unreadable
    /// project, damaged journal, undecodable media — returns nil rather than
    /// throwing: the browser shows a placeholder and `screenreel validate` explains.
    public static func thumbnail(for projectURL: URL, height: Int = 180) async -> CGImage? {
        let cache = cacheURL(for: projectURL, height: height)
        if let cached = loadPNG(at: cache) {
            return cached
        }
        let marker = failureMarkerURL(for: projectURL, height: height)
        let stamp = modificationStamp(of: projectURL)
        if let previous = try? String(contentsOf: marker, encoding: .utf8),
            previous == stamp
        {
            return nil  // known-bad and unchanged since; don't re-parse it
        }
        func rememberFailure() {
            try? FileManager.default.createDirectory(
                at: marker.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? Data(stamp.utf8).write(to: marker, options: .atomic)
        }
        guard let composition = try? ProjectComposition(
            projectURL: projectURL, previewDecodeMaxHeight: 360)
        else {
            rememberFailure()
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
            rememberFailure()
            return nil
        }
        guard let cgImage = renderContext.createCGImage(image, from: image.extent) else {
            rememberFailure()
            return nil
        }
        try? FileManager.default.removeItem(at: marker)
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
