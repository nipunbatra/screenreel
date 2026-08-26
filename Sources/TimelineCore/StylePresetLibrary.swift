import Foundation

/// A named look — background, screen treatment, cursor, and camera styling —
/// so a course or channel keeps a consistent style across recordings.
/// Zooms and trims stay per-project.
public struct StylePreset: Codable, Identifiable, Equatable, Sendable {
    public var name: String
    public var style: FrameStyle
    public var cursor: CursorSettings
    public var camera: CameraStyle
    public var id: String { name }

    public init(
        name: String, style: FrameStyle,
        cursor: CursorSettings = CursorSettings(),
        camera: CameraStyle = CameraStyle()
    ) {
        self.name = name
        self.style = style
        self.cursor = cursor
        self.camera = camera
    }
}

/// File-backed preset list: value semantics plus explicit load/save so the
/// persistence rules are unit-testable without the app. Saving is atomic;
/// an unreadable file loads as empty rather than failing — but a corrupt
/// file is first preserved aside as `<name>.corrupt-<timestamp>`, so a
/// later save can never overwrite the only evidence.
public struct StylePresetLibrary: Equatable, Sendable {
    public private(set) var presets: [StylePreset]

    public init(presets: [StylePreset] = []) {
        self.presets = presets
    }

    public static func load(from url: URL) -> StylePresetLibrary {
        guard let data = try? Data(contentsOf: url) else {
            return StylePresetLibrary()  // absent file: legitimately empty
        }
        guard let loaded = try? JSONDecoder().decode([StylePreset].self, from: data) else {
            // Exists but does not parse: move the original bytes aside for
            // forensics, then start empty.
            CorruptSidecar.preserve(url)
            return StylePresetLibrary()
        }
        return StylePresetLibrary(presets: loaded)
    }

    public func save(to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(presets).write(to: url, options: .atomic)
    }

    /// Insert or replace by name; the list stays name-sorted.
    public mutating func upsert(_ preset: StylePreset) {
        presets.removeAll { $0.name == preset.name }
        presets.append(preset)
        presets.sort {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    public mutating func remove(named name: String) {
        presets.removeAll { $0.name == name }
    }
}
