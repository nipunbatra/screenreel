import Foundation

/// Where recordings live by default, including the one-time move from the
/// product's former name. Pure enough to test against a temporary
/// directory: nothing here touches the real home folder unless asked.
public enum RecordingsFolder {
    public static let folderName = "Screenreel"
    /// The folder older builds used (the product was called "Aks").
    public static let legacyFolderName = "Aks"

    public enum Migration: Equatable, Sendable {
        /// Nothing to do: the current folder already exists (or neither does).
        case none
        /// The legacy folder was renamed to the current name.
        case moved
        /// Both folders exist; the legacy one is left alone.
        case keptBoth
        /// The rename failed; the legacy folder stays reachable.
        case failed(String)
    }

    /// Resolve the default recordings folder inside `moviesDirectory`,
    /// renaming `Aks` to `Screenreel` when only the old one exists (same
    /// volume, atomic; the packages inside are untouched). Returns the
    /// folder to use and what happened.
    @discardableResult
    public static func resolveDefault(
        in moviesDirectory: URL,
        fileManager fm: FileManager = .default
    ) -> (url: URL, migration: Migration) {
        let current = moviesDirectory.appendingPathComponent(folderName, isDirectory: true)
        let legacy = moviesDirectory.appendingPathComponent(legacyFolderName, isDirectory: true)
        let currentExists = fm.fileExists(atPath: current.path)
        let legacyExists = fm.fileExists(atPath: legacy.path)
        switch (currentExists, legacyExists) {
        case (true, true):
            return (current, .keptBoth)
        case (true, false), (false, false):
            return (current, .none)
        case (false, true):
            do {
                try fm.moveItem(at: legacy, to: current)
                return (current, .moved)
            } catch {
                return (legacy, .failed(error.localizedDescription))
            }
        }
    }
}
