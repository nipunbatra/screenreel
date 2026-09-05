import Foundation

/// Atomic manifest persistence with generation history
/// (`docs/PROJECT_FORMAT.md` §6): every save increments `generation`, and the
/// previous two manifests are kept under `.history/` until a clean close.
public actor ManifestStore {
    private let layout: ProjectLayout
    private var current: Manifest

    public init(layout: ProjectLayout, manifest: Manifest) {
        self.layout = layout
        self.current = manifest
    }

    /// Load the manifest of an existing project.
    public init(loadingFrom layout: ProjectLayout) throws {
        let data: Data
        do {
            data = try Data(contentsOf: layout.manifestURL)
        } catch {
            throw ScreenreelError.notAProject(path: layout.root.path, reason: "manifest.json unreadable: \(error)")
        }
        self.layout = layout
        self.current = try Manifest.decode(from: data, path: layout.manifestURL.path)
    }

    public var manifest: Manifest { current }

    /// Persist the first generation without archiving a predecessor.
    public func saveInitial() throws {
        precondition(current.generation == 1, "saveInitial requires generation 1")
        try AtomicFile.writeJSON(current, to: layout.manifestURL)
    }

    /// Apply a mutation, bump the generation, archive the predecessor, and
    /// atomically replace manifest.json.
    public func save(_ mutate: (inout Manifest) -> Void) throws -> Manifest {
        var next = current
        mutate(&next)
        next.generation = current.generation + 1
        next.modifiedAt = RFC3339.now()

        let fm = FileManager.default
        try fm.createDirectory(at: layout.historyDirectory, withIntermediateDirectories: true)
        let archived = layout.historyDirectory
            .appendingPathComponent("manifest-\(current.generation).json")
        if fm.fileExists(atPath: layout.manifestURL.path) {
            // The predecessor's bytes are already durable from its own save;
            // archiving by rename is metadata-only. The brief window with no
            // manifest.json is covered: recovery falls back to the newest
            // readable .history/ manifest.
            try? fm.removeItem(at: archived)
            try AtomicFile.rename(from: layout.manifestURL, to: archived)
        }
        try AtomicFile.writeJSON(next, to: layout.manifestURL)
        current = next
        try pruneHistory(keeping: 2)
        return next
    }

    /// Remove history after a clean close.
    public func clearHistoryAfterCleanClose() throws {
        try? FileManager.default.removeItem(at: layout.historyDirectory)
    }

    private func pruneHistory(keeping: Int) throws {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: layout.historyDirectory, includingPropertiesForKeys: nil) else { return }
        let manifests = entries
            .filter { $0.lastPathComponent.hasPrefix("manifest-") }
            .sorted { generationNumber($0) < generationNumber($1) }
        for stale in manifests.dropLast(keeping) {
            try? fm.removeItem(at: stale)
        }
    }

    private func generationNumber(_ url: URL) -> Int {
        let name = url.deletingPathExtension().lastPathComponent
        return Int(name.dropFirst("manifest-".count)) ?? 0
    }
}
