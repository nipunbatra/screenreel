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

    /// The old folder, when it still exists next to the current one (the
    /// browser lists both so no take disappears).
    public static func legacyFolder(in moviesDirectory: URL, fileManager fm: FileManager = .default) -> URL? {
        let legacy = moviesDirectory.appendingPathComponent(legacyFolderName, isDirectory: true)
        return isDirectory(legacy, fm) ? legacy : nil
    }

    private static func isDirectory(_ url: URL, _ fm: FileManager) -> Bool {
        var flag: ObjCBool = false
        return fm.fileExists(atPath: url.path, isDirectory: &flag) && flag.boolValue
    }

    /// Only a folder the old app made is moved: empty, or holding nothing
    /// but `.aks` packages (dotfiles ignored), none of them mid-session
    /// (a `session.lock` inside means an old build may still be writing).
    /// A user's own folder that happens to be called "Aks" is left alone.
    public static func isMigratable(_ legacy: URL, fileManager fm: FileManager = .default) -> Bool {
        guard let entries = try? fm.contentsOfDirectory(atPath: legacy.path) else { return false }
        for entry in entries where !entry.hasPrefix(".") {
            guard entry.hasSuffix(".aks") else { return false }
            let lock = legacy.appendingPathComponent(entry).appendingPathComponent("session.lock")
            if fm.fileExists(atPath: lock.path) { return false }
        }
        return true
    }

    /// Resolve the default recordings folder inside `moviesDirectory`,
    /// renaming `Aks` to `Screenreel` when only the old one exists and it
    /// is migratable (same volume, atomic; the packages inside are
    /// untouched). Returns the folder to use and what happened.
    @discardableResult
    public static func resolveDefault(
        in moviesDirectory: URL,
        fileManager fm: FileManager = .default
    ) -> (url: URL, migration: Migration) {
        let current = moviesDirectory.appendingPathComponent(folderName, isDirectory: true)
        let legacy = moviesDirectory.appendingPathComponent(legacyFolderName, isDirectory: true)
        let currentExists = isDirectory(current, fm)
        let legacyExists = isDirectory(legacy, fm)
        switch (currentExists, legacyExists) {
        case (true, true):
            return (current, .keptBoth)
        case (true, false), (false, false):
            return (current, .none)
        case (false, true):
            guard isMigratable(legacy, fileManager: fm) else { return (current, .keptBoth) }
            do {
                try fm.moveItem(at: legacy, to: current)
                return (current, .moved)
            } catch {
                return (legacy, .failed(error.localizedDescription))
            }
        }
    }
}
