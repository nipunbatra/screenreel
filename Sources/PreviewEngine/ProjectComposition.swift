import CoreImage
import Foundation
import MotionEngine
import ProjectModel
import RenderGraph
import TimelineCore

/// One project opened for evaluation: committed media + events + edit
/// document wired into the deterministic engines. **This is the single
/// composition path** — the app preview and the styled exporter both render
/// through `frame(at:)`, which is what keeps preview and export identical in
/// geometry, timing, and event evaluation (CLAUDE.md invariant).
///
/// Concurrency: NOT internally synchronized. Ownership contract: exactly one
/// task/actor drives an instance at a time (the app wraps it in an actor; the
/// exporter uses it from one task). `@unchecked Sendable` exists only so an
/// owning actor can call its async methods.
public final class ProjectComposition: @unchecked Sendable {
    public let projectURL: URL
    public let layout: ProjectLayout
    public let manifest: Manifest
    public private(set) var edits: EditDocument
    public let durationNs: Int64
    public let sourceSize: SIMD2<Double>
    public let motionTimeline: MotionTimeline
    /// Discontinuity times a zoom must never span.
    public let discontinuities: [Int64]
    /// Output↔source mapping for cuts; rebuilt when edits.clips change.
    public private(set) var clipTimeline: ClipTimeline

    private let frameProvider: SegmentFrameProvider
    private let cameraProvider: SegmentFrameProvider?
    private var cursorEngine: CursorEngine
    private var cameraEngine: CameraEngine
    private var composer: FrameComposer?
    private var outputSize: SIMD2<Double>

    private struct CursorAsset {
        let sprite: CIImage
        let hotspot: SIMD2<Double>
        let sourceSize: SIMD2<Double>
    }
    private var cursorAssets: [String: CursorAsset] = [:]
    private var fallbackCursor: CursorAsset?
    private let captureScale: Double

    public init(projectURL: URL, previewDecodeMaxHeight: Int? = nil) throws {
        self.projectURL = projectURL
        let loaded = try ProjectPackage.load(at: projectURL)
        if let reason = loaded.journal.truncationReason {
            throw AksError.journalInvalid(
                reason: "journal is damaged (\(reason)); run `aks recover` first",
                atLine: loaded.journal.truncatedAtLine ?? 0)
        }
        self.layout = loaded.layout
        self.manifest = loaded.manifest

        // Journal-committed descriptors are the source of truth.
        var segmentsByTrack: [UUID: [SegmentDescriptor]] = [:]
        var chunksByTrack: [UUID: [EventChunkDescriptor]] = [:]
        for record in loaded.journal.records {
            if record.type == .segmentCommitted,
                let segment = try? record.payload.decoded(as: SegmentDescriptor.self)
            {
                segmentsByTrack[segment.trackID, default: []].append(segment)
            }
            if record.type == .eventChunkCommitted,
                let chunk = try? record.payload.decoded(as: EventChunkDescriptor.self)
            {
                chunksByTrack[chunk.trackID, default: []].append(chunk)
            }
        }
        func mediaSegments(_ type: TrackType) -> [SegmentDescriptor] {
            loaded.manifest.tracks.filter { $0.type == type }
                .flatMap { segmentsByTrack[$0.id] ?? [] }
                .sorted { $0.sequenceInTrack < $1.sequenceInTrack }
        }
        self.screenSegments = mediaSegments(.screen)
        self.cameraSegments = mediaSegments(.camera)
        self.micSegments = mediaSegments(.microphone)
        self.systemSegments = mediaSegments(.systemAudio)
        guard !screenSegments.isEmpty else {
            throw AksError.invariantViolated("project has no committed screen segments")
        }
        self.frameProvider = try SegmentFrameProvider(
            segments: screenSegments, layout: layout,
            decodeMaxHeight: previewDecodeMaxHeight)
        self.cameraProvider = cameraSegments.isEmpty
            ? nil
            : try? SegmentFrameProvider(
                segments: cameraSegments, layout: layout,
                decodeMaxHeight: previewDecodeMaxHeight.map { min($0, 480) })
        // A static screen sends no frames while narration continues:
        // the project lasts until the LAST track ends, not the last video
        // frame (the frame provider persists the final frame past it).
        let audioEndNs = (micSegments + systemSegments)
            .map(\.normalizedEndNs).max() ?? 0
        self.durationNs = max(frameProvider.durationNs, audioEndNs)
        self.sourceSize = frameProvider.sourceSize

        // Events from every committed chunk.
        var events: [EventRecord] = []
        for track in loaded.manifest.tracks where !track.type.isMedia {
            for chunk in chunksByTrack[track.id] ?? [] {
                guard chunk.compression == .none,
                    let url = try? layout.resolve(relativePath: chunk.path),
                    let data = try? Data(contentsOf: url),
                    let text = String(data: data, encoding: .utf8)
                else { continue }
                var lineNumber = 0
                for line in text.split(separator: "\n") {
                    lineNumber += 1
                    if let record = try? EventRecord.parse(line: line, lineNumber: lineNumber) {
                        events.append(record)
                    }
                }
            }
        }
        let capture = loaded.manifest.capture
        let offsetX = capture?["eventOffsetXPx"]?.doubleValue ?? 0
        let offsetY = capture?["eventOffsetYPx"]?.doubleValue ?? 0
        // Pixels-per-point of the capture; legacy projects predate the
        // field and were recorded on Retina panels.
        self.captureScale = capture?["displayScale"]?.doubleValue ?? 2
        if offsetX != 0 || offsetY != 0 {
            events = events.map { record in
                var shifted = record
                if let x = record.xPx { shifted.xPx = x - offsetX }
                if let y = record.yPx { shifted.yPx = y - offsetY }
                return shifted
            }
        }
        self.motionTimeline = MotionTimeline(events: events)

        // Discontinuities: journal records plus flagged segments.
        var discontinuities: [Int64] = loaded.journal.records
            .filter { $0.type == .discontinuity }
            .compactMap { $0.payload["endNs"]?.integerValue ?? $0.payload["startNs"]?.integerValue }
        discontinuities.append(contentsOf: screenSegments
            .filter { $0.discontinuityBefore == true }
            .map(\.normalizedStartNs))
        self.discontinuities = discontinuities.sorted()

        // Edits: stored document, with auto-zooms generated and persisted on
        // first open (`docs/PRODUCT_SPEC.md` §3C: generate zooms from click
        // data, then edit them).
        var edits = try EditDocument.load(from: layout)
        if edits.zooms.isEmpty, edits.autoZoomEnabled {
            edits.zooms = ZoomGenerator.generate(
                timeline: motionTimeline,
                durationNs: durationNs,
                discontinuities: self.discontinuities,
                sourceSize: sourceSize)
            if !edits.zooms.isEmpty {
                try edits.save(to: layout)
            }
        }
        self.edits = edits
        self.clipTimeline = ClipTimeline(
            clips: edits.clips, sourceDurationNs: self.durationNs)
        self.outputSize = sourceSize
        self.cursorEngine = CursorEngine(
            timeline: motionTimeline, settings: edits.cursor, durationNs: durationNs)
        self.cameraEngine = CameraEngine(zooms: edits.zooms, durationNs: durationNs)
        loadCursorAssets()
        rebuildComposer()
    }

    public let screenSegments: [SegmentDescriptor]
    public let cameraSegments: [SegmentDescriptor]
    public let micSegments: [SegmentDescriptor]
    public let systemSegments: [SegmentDescriptor]

    /// Whether this recording captured any keystroke events.
    public var hasKeystrokes: Bool { !motionTimeline.keyPresses.isEmpty }

    /// Total playable duration after cuts.
    public var outputDurationNs: Int64 { clipTimeline.outputDurationNs }

    /// Effective export/preview range after trim, in OUTPUT time (cuts
    /// applied first; a project with no clips behaves exactly as before).
    public var trimmedRange: (startNs: Int64, endNs: Int64) {
        let total = outputDurationNs
        let start = max(0, edits.trimStartNs ?? 0)
        let end = min(total, edits.trimEndNs ?? total)
        return (min(start, end), max(start, end))
    }

    // MARK: - Edits

    /// Apply an edit mutation: engines rebuild deterministically, and the
    /// document is persisted atomically (never the raw media).
    public func updateEdits(_ mutate: (inout EditDocument) -> Void) throws {
        var next = edits
        mutate(&next)
        try next.save(to: layout)
        let cursorChanged = next.cursor != edits.cursor
        let zoomsChanged = next.zooms != edits.zooms
        let clipsChanged = next.clips != edits.clips
        edits = next
        if clipsChanged {
            clipTimeline = ClipTimeline(
                clips: next.clips, sourceDurationNs: durationNs)
        }
        if cursorChanged {
            cursorEngine = CursorEngine(
                timeline: motionTimeline, settings: next.cursor, durationNs: durationNs)
        }
        if zoomsChanged {
            cameraEngine = CameraEngine(zooms: next.zooms, durationNs: durationNs)
        }
        rebuildComposer()
    }

    /// Regenerate auto zooms, replacing previous generated segments but never
    /// touching manual ones (`docs/MOTION_ENGINE.md` §6).
    public func regenerateZooms() throws {
        let generated = ZoomGenerator.generate(
            timeline: motionTimeline,
            durationNs: durationNs,
            discontinuities: discontinuities,
            sourceSize: sourceSize)
        try updateEdits { edits in
            let manual = edits.zooms.filter { $0.origin == "manual" }
            edits.zooms = (generated + manual).sorted { $0.startNs < $1.startNs }
        }
    }

    /// Set the output canvas size (preview viewport or export resolution).
    public func setOutputSize(_ size: SIMD2<Double>) {
        guard size.x > 0, size.y > 0, size != outputSize else { return }
        outputSize = size
        rebuildComposer()
    }

    public var canvasSize: SIMD2<Double> { outputSize }

    // MARK: - Evaluation

    /// Map a canvas-pixel point back to a normalized source focal
    /// (0…1), using the exact geometry of the frame at `outputNs` — the
    /// editor's click-to-aim for zoom focal points.
    public func sourceFocal(
        atCanvasPoint canvasPx: SIMD2<Double>, outputNs: Int64
    ) -> SIMD2<Double> {
        let sourceTime = clipTimeline.sourceTime(forOutput: outputNs)
        let composer = FrameComposer(
            style: edits.style, outputSize: outputSize, sourceSize: sourceSize)
        let geometry = composer.geometry(camera: cameraEngine.state(at: sourceTime))
        let sourcePx = (canvasPx - geometry.contentOffset) / geometry.contentScale
        return SIMD2(
            min(1, max(0, sourcePx.x / max(1, sourceSize.x))),
            min(1, max(0, sourcePx.y / max(1, sourceSize.y))))
    }

    public func cameraState(at timeNs: Int64) -> CameraState {
        cameraEngine.state(at: timeNs)
    }

    public func cursorState(at timeNs: Int64) -> CursorFrameState? {
        cursorEngine.state(at: timeNs)
    }

    /// The fully composed frame at an OUTPUT-timeline time (cuts applied).
    /// This is the single evaluation path for playback and export.
    public func frame(atOutput outputNs: Int64) async throws -> CIImage? {
        try await frame(
            at: clipTimeline.sourceTime(forOutput: outputNs),
            cameraIntroProgress: cameraIntroProgress(atOutput: outputNs))
    }

    /// Camera-intro interpolation at an output time: 0 while the fullscreen
    /// opening holds, easing (cubic ease-out over 600 ms) to 1 as the
    /// camera flies to its corner. Anchored at the TRIMMED range start —
    /// the exported video's first frame — so trimming fumble off the head
    /// keeps the intro at the opening. Deterministic; preview and export
    /// share it by construction.
    public func cameraIntroProgress(atOutput outputNs: Int64) -> Double {
        let introNs = edits.camera.introNs
        guard introNs > 0 else { return 1 }
        let springNs: Int64 = 600_000_000
        let anchorNs = trimmedRange.startNs
        // The hold may take at most HALF the playable range (minus the
        // flight), so cutting a 60 s recording down to an 8 s tail with a
        // 10 s intro still shows screen content — never an all-camera
        // export.
        let availableNs = max(0, trimmedRange.endNs - anchorNs)
        let effectiveHoldNs = min(introNs, max(0, availableNs / 2 - springNs))
        let holdEndNs = anchorNs + effectiveHoldNs
        guard outputNs >= holdEndNs else { return 0 }
        let t = min(1.0, Double(outputNs - holdEndNs) / Double(springNs))
        return 1 - pow(1 - t, 3)
    }

    /// The fully composed output frame at a SOURCE time `timeNs`.
    public func frame(
        at timeNs: Int64, cameraIntroProgress: Double = 1
    ) async throws -> CIImage? {
        guard let composer else { return nil }
        guard let screen = try await frameProvider.frame(at: timeNs) else { return nil }
        let camera = cameraEngine.state(at: timeNs)
        let cursor = cursorEngine.state(at: timeNs)
        var input = FrameComposer.Input(screenImage: screen, camera: camera)
        if let cursor, edits.cursor.showCursor {
            let asset = cursorAsset(for: cursor.cursorID)
            input.cursor = cursor
            input.cursorSprite = asset?.sprite
            input.cursorHotspot = asset?.hotspot ?? .zero
            input.cursorSpriteSourceSize = asset?.sourceSize ?? .zero
            input.cursorSizeMultiplier = edits.cursor.sizeMultiplier
        }
        if let cameraProvider, !edits.camera.hidden {
            input.cameraImage = try? await cameraProvider.frame(at: timeNs)
            input.cameraStyle = edits.camera
            input.cameraIntroProgress = cameraIntroProgress
        }
        if edits.cursor.clickRipplesEnabled {
            input.clickRipples = ClickRipples.active(
                downs: motionTimeline.downs, atSource: timeNs
            ).map { ($0.position, $0.progress) }
        }
        if edits.cursor.keystrokeOverlayEnabled,
            !motionTimeline.keyPresses.isEmpty
        {
            input.keystrokeChips = KeystrokeChips.chips(
                presses: motionTimeline.keyPresses, atSource: timeNs
            ).map { ($0.label, $0.progress) }
        }
        return composer.compose(input)
    }

    /// The raw (unstyled) source frame, for A/B and diagnostics.
    public func rawFrame(at timeNs: Int64) async throws -> CIImage? {
        try await frameProvider.frame(at: timeNs)
    }

    // MARK: - Internals

    private func rebuildComposer() {
        composer = FrameComposer(
            style: edits.style, outputSize: outputSize, sourceSize: sourceSize)
    }

    private func cursorAsset(for id: String?) -> CursorAsset? {
        if let id, let asset = cursorAssets[id] { return asset }
        return fallbackCursor
    }

    /// Load recorded cursor descriptors; when none exist (synthetic projects,
    /// denied permissions) an original vector arrow is generated so the
    /// cursor track still renders (`docs/MOTION_ENGINE.md` §5).
    private func loadCursorAssets() {
        let fm = FileManager.default
        if let entries = try? fm.contentsOfDirectory(
            at: layout.cursorsDirectory, includingPropertiesForKeys: nil)
        {
            for url in entries where url.pathExtension == "json" {
                guard let data = try? Data(contentsOf: url),
                    let descriptor = try? JSONDecoder().decode(CursorDescriptor.self, from: data)
                else { continue }
                var sprite: CIImage?
                if let imagePath = descriptor.imagePath,
                    let imageURL = try? layout.resolve(relativePath: imagePath)
                {
                    sprite = CIImage(contentsOf: imageURL)
                }
                guard let sprite else { continue }
                cursorAssets[descriptor.id] = CursorAsset(
                    sprite: sprite,
                    hotspot: SIMD2(descriptor.hotspotXPx, descriptor.hotspotYPx),
                    sourceSize: CursorSpriteMath.sourceSize(
                        spriteWidthPx: descriptor.widthPx,
                        spriteHeightPx: descriptor.heightPx,
                        backingScale: descriptor.backingScale,
                        captureScale: captureScale))
            }
        }
        fallbackCursor = Self.makeVectorArrow()
        if fallbackCursor == nil {
            fallbackCursor = cursorAssets.values.first
        }
    }

    /// Original Aks arrow drawn with CoreGraphics (no external assets).
    private static func makeVectorArrow() -> CursorAsset? {
        let size = 64
        guard let context = CGContext(
            data: nil, width: size, height: size,
            bitsPerComponent: 8, bytesPerRow: size * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        // Classic pointer silhouette in a 64×64 box, hotspot at the tip
        // (top-left). Path drawn in CG's bottom-left space.
        let path = CGMutablePath()
        func point(_ x: Double, _ y: Double) -> CGPoint {
            CGPoint(x: x, y: Double(size) - y)  // author in top-left coords
        }
        path.move(to: point(8, 4))
        path.addLine(to: point(8, 46))
        path.addLine(to: point(18, 37))
        path.addLine(to: point(24, 52))
        path.addLine(to: point(31, 49))
        path.addLine(to: point(25, 34))
        path.addLine(to: point(38, 33))
        path.closeSubpath()
        context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        context.addPath(path)
        context.fillPath()
        context.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.setLineWidth(3)
        context.addPath(path)
        context.strokePath()
        guard let image = context.makeImage() else { return nil }
        return CursorAsset(
            sprite: CIImage(cgImage: image),
            hotspot: SIMD2(8, 4),
            sourceSize: SIMD2(32, 32))
    }
}
