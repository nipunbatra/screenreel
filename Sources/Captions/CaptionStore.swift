import Foundation
import ProjectModel

/// Caption persistence: cues live beside the edit document in the project
/// package (`edits/captions.json`), written atomically. Transcription is
/// paid once per project; edits to cue text survive relaunches. Raw media
/// untouched, as ever.
public enum CaptionStore {

    public static func url(in layout: ProjectLayout) -> URL {
        layout.editsDirectory.appendingPathComponent("captions.json")
    }

    /// Missing file → empty. An unreadable existing file is preserved
    /// aside (never overwritten) and reported by throwing.
    public static func load(from layout: ProjectLayout) throws -> [CaptionCue] {
        let fileURL = url(in: layout)
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return []
        }
        do {
            let data = try Data(contentsOf: fileURL)
            return try JSONDecoder().decode([CaptionCue].self, from: data)
        } catch {
            let stamp = Int(Date().timeIntervalSince1970)
            let aside = fileURL.deletingPathExtension()
                .appendingPathExtension("corrupt-\(stamp).json")
            try? FileManager.default.moveItem(at: fileURL, to: aside)
            throw error
        }
    }

    public static func save(_ cues: [CaptionCue], to layout: ProjectLayout) throws {
        try FileManager.default.createDirectory(
            at: layout.editsDirectory, withIntermediateDirectories: true)
        try AtomicFile.writeJSON(cues, to: url(in: layout))
    }
}
