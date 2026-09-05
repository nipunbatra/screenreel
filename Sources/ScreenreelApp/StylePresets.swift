import Foundation
import Observation
import TimelineCore

/// App-side wrapper over `StylePresetLibrary` (TimelineCore): observation +
/// the on-disk location. Presets persist app-wide under Application
/// Support; the folder name is a stable on-disk identifier, independent of
/// the display-name rebrand.
@Observable
@MainActor
final class StylePresetStore {
    private var library: StylePresetLibrary
    var presets: [StylePreset] { library.presets }

    private static var fileURL: URL {
        FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Screenreel", isDirectory: true)
            .appendingPathComponent("style-presets.json")
    }

    init() {
        library = StylePresetLibrary.load(from: Self.fileURL)
    }

    func save(_ preset: StylePreset) {
        library.upsert(preset)
        try? library.save(to: Self.fileURL)
    }

    func remove(named name: String) {
        library.remove(named: name)
        try? library.save(to: Self.fileURL)
    }
}
