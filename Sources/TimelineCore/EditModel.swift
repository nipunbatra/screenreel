import Foundation
import ProjectModel

// Persisted edit data (`edits/timeline.json`). All of it is non-destructive
// project data: raw media is never touched, and numeric values are stored so
// preset definitions can evolve without changing old videos.

/// Spring parameters as stored in the project (`docs/MOTION_ENGINE.md` §4).
public struct SpringParameters: Codable, Sendable, Equatable {
    public var stiffness: Double
    public var damping: Double
    public var mass: Double

    public init(stiffness: Double, damping: Double, mass: Double) {
        self.stiffness = stiffness
        self.damping = damping
        self.mass = mass
    }

    // Recommended defaults measured independently (spec §4).
    public static let cursorNormal = SpringParameters(stiffness: 470, damping: 70, mass: 3)
    public static let cursorQuickHop = SpringParameters(stiffness: 530, damping: 40, mass: 1)
    public static let cursorHeld = SpringParameters(stiffness: 1000, damping: 40, mass: 1)
    public static let clickScale = SpringParameters(stiffness: 700, damping: 30, mass: 1)
    public static let screenCamera = SpringParameters(stiffness: 200, damping: 40, mass: 2.25)
}

/// User-tunable cursor motion settings.
public struct CursorSettings: Codable, Sendable, Equatable {
    public var showCursor: Bool
    public var sizeMultiplier: Double
    /// False renders raw recorded positions with no spring.
    public var smoothed: Bool
    public var idleHideAfterNs: Int64?
    public var normalSpring: SpringParameters
    public var quickHopSpring: SpringParameters
    public var heldSpring: SpringParameters
    public var clickSpring: SpringParameters
    public var quickHopWindowNs: Int64
    public var clickSquashDurationNs: Int64
    public var clickSquashScale: Double
    /// Expanding ring on every click. Optional so documents from before
    /// the field decode unchanged; nil means enabled.
    public var clickRipples: Bool?
    public var clickRipplesEnabled: Bool { clickRipples ?? true }
    /// Shortcut chips for recordings that captured keystrokes; nil = on.
    public var keystrokeOverlay: Bool?
    public var keystrokeOverlayEnabled: Bool { keystrokeOverlay ?? true }

    public init(
        showCursor: Bool = true,
        sizeMultiplier: Double = 1.0,
        smoothed: Bool = true,
        idleHideAfterNs: Int64? = nil,
        normalSpring: SpringParameters = .cursorNormal,
        quickHopSpring: SpringParameters = .cursorQuickHop,
        heldSpring: SpringParameters = .cursorHeld,
        clickSpring: SpringParameters = .clickScale,
        quickHopWindowNs: Int64 = 175_000_000,
        clickSquashDurationNs: Int64 = 130_000_000,
        clickSquashScale: Double = 0.8
    ) {
        self.showCursor = showCursor
        self.sizeMultiplier = sizeMultiplier
        self.smoothed = smoothed
        self.idleHideAfterNs = idleHideAfterNs
        self.normalSpring = normalSpring
        self.quickHopSpring = quickHopSpring
        self.heldSpring = heldSpring
        self.clickSpring = clickSpring
        self.quickHopWindowNs = quickHopWindowNs
        self.clickSquashDurationNs = clickSquashDurationNs
        self.clickSquashScale = clickSquashScale
    }
}

/// One zoom range on the timeline (`docs/MOTION_ENGINE.md` §6-7).
public struct ZoomSegment: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var startNs: Int64
    public var endNs: Int64
    /// 1.0–4.5×.
    public var scale: Double
    /// Screen-local normalized focal point.
    public var focalX: Double
    public var focalY: Double
    public var instant: Bool
    /// "generated" or "manual".
    public var origin: String
    public var generatorVersion: Int?
    public var disabled: Bool?

    public init(
        id: UUID = UUID(),
        startNs: Int64,
        endNs: Int64,
        scale: Double = 2.0,
        focalX: Double = 0.5,
        focalY: Double = 0.5,
        instant: Bool = false,
        origin: String = "manual",
        generatorVersion: Int? = nil,
        disabled: Bool? = nil
    ) {
        self.id = id
        self.startNs = startNs
        self.endNs = endNs
        self.scale = min(4.5, max(1.0, scale))
        self.focalX = focalX
        self.focalY = focalY
        self.instant = instant
        self.origin = origin
        self.generatorVersion = generatorVersion
        self.disabled = disabled
    }

    // Decode clamps mirror the memberwise init: a hand-edited document
    // with scale 100 or focal 9 must not become a 100× zoom.
    private enum CodingKeys: String, CodingKey {
        case id, startNs, endNs, scale, focalX, focalY, instant
        case origin, generatorVersion, disabled
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.startNs = try c.decode(Int64.self, forKey: .startNs)
        self.endNs = try c.decode(Int64.self, forKey: .endNs)
        let rawScale = try c.decode(Double.self, forKey: .scale)
        self.scale = min(4.5, max(1.0, rawScale.isFinite ? rawScale : 1))
        let x = try c.decode(Double.self, forKey: .focalX)
        let y = try c.decode(Double.self, forKey: .focalY)
        self.focalX = min(1, max(0, x.isFinite ? x : 0.5))
        self.focalY = min(1, max(0, y.isFinite ? y : 0.5))
        self.instant = try c.decode(Bool.self, forKey: .instant)
        self.origin = try c.decode(String.self, forKey: .origin)
        self.generatorVersion = try c.decodeIfPresent(Int.self, forKey: .generatorVersion)
        self.disabled = try c.decodeIfPresent(Bool.self, forKey: .disabled)
    }

    public var isActive: Bool { disabled != true }

    /// Minimum editable zoom length.
    public static let minLengthNs: Int64 = 300_000_000

    /// Timeline-drag edits as pure, clamped functions so the UI gesture layer
    /// stays logic-free and the invariants are unit-testable: results always
    /// lie in [0, duration], keep at least `minLengthNs`, and a move never
    /// changes the length.
    public func moved(byNs deltaNs: Int64, durationNs: Int64) -> ZoomSegment {
        var result = self
        // A hostile over-long segment shrinks to fit rather than escaping.
        let length = min(max(endNs - startNs, Self.minLengthNs), durationNs)
        let start = max(0, min(startNs + deltaNs, durationNs - length))
        result.startNs = start
        result.endNs = start + length
        return result
    }

    public func resizingStart(byNs deltaNs: Int64) -> ZoomSegment {
        var result = self
        result.startNs = max(0, min(startNs + deltaNs, endNs - Self.minLengthNs))
        return result
    }

    public func resizingEnd(byNs deltaNs: Int64, durationNs: Int64) -> ZoomSegment {
        var result = self
        result.endNs = min(durationNs, max(endNs + deltaNs, startNs + Self.minLengthNs))
        return result
    }
}

/// Canvas/background/screen treatment (`docs/PRODUCT_SPEC.md` §5).
public struct FrameStyle: Codable, Sendable, Equatable {
    public struct Color: Codable, Sendable, Equatable {
        public var red: Double
        public var green: Double
        public var blue: Double
        public var alpha: Double

        public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
            self.red = red
            self.green = green
            self.blue = blue
            self.alpha = alpha
        }

        public static let black = Color(red: 0, green: 0, blue: 0)
        public static let white = Color(red: 1, green: 1, blue: 1)
    }

    public enum Background: Codable, Sendable, Equatable {
        case none
        case solid(Color)
        case linearGradient(top: Color, bottom: Color)
        /// Wallpaper-grade procedural mesh: a vertical base gradient with
        /// soft radial lights at deterministic positions. Fully vector —
        /// crisp at any export size, no bundled assets.
        case mesh(base: Color, glow1: Color, glow2: Color)
    }

    public var background: Background
    /// Padding as a fraction of the shorter output edge (0–0.25).
    public var padding: Double
    /// Corner radius as a fraction of the shorter screen edge (0–0.1).
    public var cornerRadius: Double
    public var shadowOpacity: Double
    /// Shadow blur radius as a fraction of the shorter output edge.
    public var shadowRadius: Double
    /// Output canvas aspect ratio (width ÷ height); nil follows the source.
    /// The screen card aspect-fits inside, so 9:16/1:1 reframes never crop
    /// or distort (`docs/PRODUCT_SPEC.md` §5 output aspect).
    public var canvasAspect: Double?

    public init(
        background: Background = .linearGradient(
            top: Color(red: 0.16, green: 0.19, blue: 0.30),
            bottom: Color(red: 0.06, green: 0.07, blue: 0.12)),
        padding: Double = 0.05,
        cornerRadius: Double = 0.02,
        shadowOpacity: Double = 0.45,
        shadowRadius: Double = 0.02,
        canvasAspect: Double? = nil
    ) {
        self.background = background
        self.padding = padding
        self.cornerRadius = cornerRadius
        self.shadowOpacity = shadowOpacity
        self.shadowRadius = shadowRadius
        self.canvasAspect = canvasAspect
    }

    // Persisted values are user-editable JSON: clamp on decode so garbage
    // can never reach the composer/exporter (padding ≥ 0.5 produced
    // negative export dimensions).
    private enum CodingKeys: String, CodingKey {
        case background, padding, cornerRadius, shadowOpacity, shadowRadius
        case canvasAspect
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.background = try c.decode(Background.self, forKey: .background)
        self.padding = min(0.25, max(0, try c.decode(Double.self, forKey: .padding)))
        self.cornerRadius = min(0.1, max(0, try c.decode(Double.self, forKey: .cornerRadius)))
        self.shadowOpacity = min(1, max(0, try c.decode(Double.self, forKey: .shadowOpacity)))
        self.shadowRadius = min(0.2, max(0, try c.decode(Double.self, forKey: .shadowRadius)))
        if let aspect = try c.decodeIfPresent(Double.self, forKey: .canvasAspect),
            aspect.isFinite, aspect > 0.1, aspect < 10
        {
            self.canvasAspect = aspect
        } else {
            self.canvasAspect = nil
        }
    }

    /// Raw look: no styling at all.
    public static let raw = FrameStyle(
        background: .none, padding: 0, cornerRadius: 0,
        shadowOpacity: 0, shadowRadius: 0)
}

extension ZoomSegment {
    /// A manual copy placed immediately after this segment, clamped so it
    /// stays inside the recording. Used by the timeline's Duplicate action.
    public func duplicatedAfter(durationNs: Int64) -> ZoomSegment {
        var copy = self
        copy.id = UUID()
        copy.origin = "manual"
        let length = min(endNs - startNs, durationNs)
        if endNs + Self.minLengthNs <= durationNs {
            // Room after: shrink to fit the tail if needed.
            copy.startNs = endNs
            copy.endNs = min(endNs + length, durationNs)
        } else {
            // No room after: place before the original instead of landing
            // exactly on top of it (an invisible, do-nothing duplicate).
            copy.endNs = startNs
            copy.startNs = max(0, startNs - length)
            if copy.endNs - copy.startNs < Self.minLengthNs {
                copy.startNs = max(0, min(startNs, durationNs - length))
                copy.endNs = min(copy.startNs + length, durationNs)
            }
        }
        return copy
    }
}

/// Adaptive tick spacing for timeline rulers: the smallest step from a
/// human ladder (1 s … 15 min) that keeps at most ~12 labeled ticks.
public enum TimelineRuler {
    public static func stepSeconds(forDuration seconds: Double) -> Double {
        let ladder: [Double] = [1, 2, 5, 10, 15, 30, 60, 120, 300, 600]
        for step in ladder where seconds / step <= 12 {
            return step
        }
        return 900
    }

    /// The label step for an actual pixel width: the duration-based step,
    /// doubled until adjacent labels have at least `minimumLabelSpacing`
    /// pixels between them — overlapping time labels are worse than fewer
    /// labels.
    public static func labelStep(
        forDuration seconds: Double, width: Double,
        minimumLabelSpacing: Double = 56
    ) -> Double {
        var step = stepSeconds(forDuration: seconds)
        guard seconds > 0, width > 0 else { return step }
        while width * step / seconds < minimumLabelSpacing, step < seconds {
            step *= 2
        }
        return step
    }
}

/// Camera picture-in-picture styling. The raw camera track is untouched;
/// this only affects composition, so every choice is revisable after
/// recording.
public struct CameraStyle: Codable, Sendable, Equatable {
    public enum Corner: String, Codable, Sendable, CaseIterable {
        case topLeft, topRight, bottomLeft, bottomRight
    }
    public enum Shape: String, Codable, Sendable, CaseIterable {
        case rounded, circle, square
    }

    /// Hide the camera in the composition without touching the raw track.
    public var hidden: Bool
    public var corner: Corner
    /// PiP width as a fraction of the shorter output edge (0.1–0.5).
    public var size: Double
    public var shape: Shape
    /// Margin from the canvas edges as a fraction of the shorter output edge.
    public var margin: Double
    /// Scale applied while a zoom is active — the camera shrinks out of
    /// the way during zooms; 1 disables.
    public var zoomedScale: Double
    /// Mirror horizontally (what people expect from a selfie view).
    public var mirrored: Bool
    /// Fullscreen camera opening: for the first `introNs` of OUTPUT time
    /// the camera fills the canvas, then springs into its corner PiP.
    /// 0 disables (the default, and what documents without the field get).
    public var introNs: Int64

    public init(
        hidden: Bool = false,
        corner: Corner = .bottomRight,
        size: Double = 0.24,
        shape: Shape = .rounded,
        margin: Double = 0.028,
        zoomedScale: Double = 0.7,
        mirrored: Bool = true,
        introNs: Int64 = 0
    ) {
        self.hidden = hidden
        self.corner = corner
        self.size = size
        self.shape = shape
        self.margin = margin
        self.zoomedScale = zoomedScale
        self.mirrored = mirrored
        self.introNs = introNs
    }

    private enum CodingKeys: String, CodingKey {
        case hidden, corner, size, shape, margin, zoomedScale, mirrored,
            introNs
    }

    /// Tolerant decoding: documents written before a field existed get its
    /// default, and hostile values clamp to sane ranges (the same contract
    /// as FrameStyle/ZoomSegment).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        hidden = try c.decodeIfPresent(Bool.self, forKey: .hidden) ?? false
        // try? on the enums: an unknown raw value from a NEWER build must
        // degrade to the default, not shunt the document to .corrupt-*.
        corner =
            (try? c.decodeIfPresent(Corner.self, forKey: .corner)) ?? .bottomRight
            ?? .bottomRight
        size = min(
            0.5, max(0.1, try c.decodeIfPresent(Double.self, forKey: .size) ?? 0.24))
        shape = (try? c.decodeIfPresent(Shape.self, forKey: .shape)) ?? .rounded
            ?? .rounded
        margin = min(
            0.2, max(0.0, try c.decodeIfPresent(Double.self, forKey: .margin) ?? 0.028))
        zoomedScale = min(
            1.0,
            max(0.3, try c.decodeIfPresent(Double.self, forKey: .zoomedScale) ?? 0.7))
        mirrored = try c.decodeIfPresent(Bool.self, forKey: .mirrored) ?? true
        introNs = min(
            30_000_000_000,
            max(0, try c.decodeIfPresent(Int64.self, forKey: .introNs) ?? 0))
    }
}

/// The versioned edit document persisted at `edits/timeline.json`
/// (`docs/PROJECT_FORMAT.md` §2). Absent file means default edits.
public struct EditDocument: Codable, Sendable, Equatable {
    public var schemaVersion: Int
    public var style: FrameStyle
    public var cursor: CursorSettings
    public var camera: CameraStyle
    public var zooms: [ZoomSegment]
    /// Kept spans of the source (cuts). Empty = whole recording.
    public var clips: [Clip]
    public var autoZoomEnabled: Bool
    /// Spectral noise reduction on the mic track at export time (raw audio
    /// is never modified).
    public var micNoiseReduction: Bool
    public var music: BackgroundMusic?
    /// Optional trim of the exported/previewed range.
    public var trimStartNs: Int64?
    public var trimEndNs: Int64?

    public init(
        style: FrameStyle = FrameStyle(),
        cursor: CursorSettings = CursorSettings(),
        camera: CameraStyle = CameraStyle(),
        zooms: [ZoomSegment] = [],
        clips: [Clip] = [],
        autoZoomEnabled: Bool = true,
        micNoiseReduction: Bool = true,
        music: BackgroundMusic? = nil,
        trimStartNs: Int64? = nil,
        trimEndNs: Int64? = nil
    ) {
        self.schemaVersion = ProjectSchema.currentVersion
        self.style = style
        self.cursor = cursor
        self.camera = camera
        self.zooms = zooms
        self.clips = clips
        self.autoZoomEnabled = autoZoomEnabled
        self.micNoiseReduction = micNoiseReduction
        self.music = music
        self.trimStartNs = trimStartNs
        self.trimEndNs = trimEndNs
    }

    // Documents written before the camera field existed decode to the
    // default style rather than failing.
    private enum CodingKeys: String, CodingKey {
        case schemaVersion, style, cursor, camera, zooms, clips
        case autoZoomEnabled, micNoiseReduction, music, trimStartNs, trimEndNs
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.schemaVersion = try c.decode(Int.self, forKey: .schemaVersion)
        self.style = try c.decode(FrameStyle.self, forKey: .style)
        self.cursor = try c.decode(CursorSettings.self, forKey: .cursor)
        self.camera = try c.decodeIfPresent(CameraStyle.self, forKey: .camera) ?? CameraStyle()
        self.zooms = try c.decode([ZoomSegment].self, forKey: .zooms)
        self.clips = try c.decodeIfPresent([Clip].self, forKey: .clips) ?? []
        self.autoZoomEnabled = try c.decode(Bool.self, forKey: .autoZoomEnabled)
        // Legacy documents keep their exports byte-stable: no silent
        // enhancement appears on projects that never chose it.
        self.micNoiseReduction =
            try c.decodeIfPresent(Bool.self, forKey: .micNoiseReduction) ?? false
        self.music = try c.decodeIfPresent(BackgroundMusic.self, forKey: .music)
        self.trimStartNs = try c.decodeIfPresent(Int64.self, forKey: .trimStartNs)
        self.trimEndNs = try c.decodeIfPresent(Int64.self, forKey: .trimEndNs)
    }

    public static func url(in layout: ProjectLayout) -> URL {
        layout.editsDirectory.appendingPathComponent("timeline.json")
    }

    /// Load the project's edit document; a missing file yields defaults, a
    /// newer schema is rejected with an actionable error, and a corrupt file
    /// is preserved aside as `timeline.json.corrupt-<timestamp>` before the
    /// error surfaces — the original bytes must survive for forensics.
    public static func load(from layout: ProjectLayout) throws -> EditDocument {
        let url = Self.url(in: layout)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return EditDocument()
        }
        // The file exists: any read error is a real error. Mapping it to
        // defaults silently destroyed user edits (auto-zoom regeneration
        // then SAVED the defaults over the real document).
        let data = try Data(contentsOf: url)
        let document: EditDocument
        do {
            document = try JSONDecoder().decode(EditDocument.self, from: data)
        } catch {
            // Corrupt, not merely newer: move the evidence aside so no later
            // save can overwrite it, then surface the failure.
            CorruptSidecar.preserve(url)
            throw error
        }
        guard document.schemaVersion <= ProjectSchema.currentVersion else {
            // A valid document from a newer build is data, not corruption:
            // it stays exactly where it is for that newer build to read.
            throw ScreenreelError.schemaTooNew(
                found: document.schemaVersion,
                supported: ProjectSchema.currentVersion,
                path: url.path)
        }
        return document
    }

    /// Atomic save (never partially written).
    public func save(to layout: ProjectLayout) throws {
        try FileManager.default.createDirectory(
            at: layout.editsDirectory, withIntermediateDirectories: true)
        try AtomicFile.writeJSON(self, to: Self.url(in: layout))
    }
}

/// Moves an unparseable sidecar file aside as `<name>.corrupt-<timestamp>`
/// so the original bytes survive for forensics — a corrupt
/// store is never overwritten. Move-only: nothing is deleted or
/// replaced, and a name collision picks a fresh suffix instead of
/// overwriting an earlier forensic copy.
enum CorruptSidecar {
    @discardableResult
    static func preserve(_ url: URL) -> URL? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return nil }
        let stamp = RFC3339.now().replacingOccurrences(of: ":", with: "-")
        let directory = url.deletingLastPathComponent()
        for attempt in 0..<100 {
            let suffix = attempt == 0 ? "" : "-\(attempt)"
            let candidate = directory.appendingPathComponent(
                "\(url.lastPathComponent).corrupt-\(stamp)\(suffix)")
            guard !fm.fileExists(atPath: candidate.path) else { continue }
            guard (try? fm.moveItem(at: url, to: candidate)) != nil else { continue }
            return candidate
        }
        // Preservation failed; the original stays untouched in place.
        return nil
    }
}
