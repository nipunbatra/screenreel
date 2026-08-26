import Foundation

/// Cheap project metadata for browsers and lists: reads ONLY
/// `manifest.json` (a few KB), never the journal or media. A full
/// `ProjectPackage.load` parses the whole write-ahead journal, which for a
/// long recording is megabytes of JSONL — far too heavy to run per card on
/// the UI thread.
public struct ProjectQuickInfo: Sendable, Equatable {
    public var durationNs: Int64?
    public var state: ProjectState?
    public var modified: Date

    public init(durationNs: Int64?, state: ProjectState?, modified: Date) {
        self.durationNs = durationNs
        self.state = state
        self.modified = modified
    }

    /// nil when the directory is not a readable project package.
    public static func read(at projectURL: URL) -> ProjectQuickInfo? {
        let layout = ProjectLayout(root: projectURL)
        guard let data = try? Data(contentsOf: layout.manifestURL),
            let manifest = try? Manifest.decode(from: data, path: layout.manifestURL.path)
        else { return nil }
        let modified = (try? projectURL.resourceValues(
            forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
        return ProjectQuickInfo(
            durationNs: manifest.durationNs,
            state: .some(manifest.state),
            modified: modified)
    }
}
