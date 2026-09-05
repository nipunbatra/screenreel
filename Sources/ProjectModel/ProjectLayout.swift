import Foundation

/// Canonical paths inside a `.screenreel` package (`docs/PROJECT_FORMAT.md` §2) and
/// the naming scheme for segments, chunks, and descriptors.
public struct ProjectLayout: Sendable {
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    public var manifestURL: URL { root.appendingPathComponent("manifest.json") }
    public var journalURL: URL { root.appendingPathComponent("journal.jsonl") }
    public var sessionLockURL: URL { root.appendingPathComponent("session.lock") }
    public var historyDirectory: URL { root.appendingPathComponent(".history") }

    public var rawDirectory: URL { root.appendingPathComponent("raw") }
    public var screenDirectory: URL { rawDirectory.appendingPathComponent("screen") }
    public var microphoneDirectory: URL { rawDirectory.appendingPathComponent("microphone") }
    public var systemAudioDirectory: URL { rawDirectory.appendingPathComponent("system-audio") }
    public var cameraDirectory: URL { rawDirectory.appendingPathComponent("camera") }

    public var eventsDirectory: URL { root.appendingPathComponent("events") }
    public var cursorsDirectory: URL { eventsDirectory.appendingPathComponent("cursors") }

    public var editsDirectory: URL { root.appendingPathComponent("edits") }
    public var derivedDirectory: URL { root.appendingPathComponent("derived") }
    public var jobsDirectory: URL { root.appendingPathComponent("jobs") }
    public var diagnosticsDirectory: URL { root.appendingPathComponent("diagnostics") }
    public var captureLogURL: URL { diagnosticsDirectory.appendingPathComponent("capture.jsonl") }

    /// Directories created at project creation time. Derived subdirectories
    /// are created lazily by their producers.
    public var initialDirectories: [URL] {
        [
            root, rawDirectory, screenDirectory, microphoneDirectory,
            systemAudioDirectory, cameraDirectory, eventsDirectory,
            cursorsDirectory, editsDirectory, derivedDirectory, jobsDirectory,
            diagnosticsDirectory,
        ]
    }

    // MARK: Naming

    public func mediaDirectory(for type: TrackType) -> URL {
        switch type {
        case .screen: return screenDirectory
        case .microphone: return microphoneDirectory
        case .systemAudio: return systemAudioDirectory
        case .camera: return cameraDirectory
        case .cursorEvents, .clickEvents, .keyboardEvents: return eventsDirectory
        }
    }

    public static func segmentFileName(type: TrackType, displayID: Int?, sequence: Int) -> String {
        let seq = String(format: "%06d", sequence)
        switch type {
        case .screen: return "display-\(displayID ?? 0)-\(seq).mov"
        case .microphone: return "mic-\(seq).caf"
        case .systemAudio: return "system-\(seq).caf"
        case .camera: return "camera-\(seq).mov"
        case .cursorEvents, .clickEvents, .keyboardEvents:
            preconditionFailure("event tracks use chunkFileName")
        }
    }

    public static func chunkFileName(kind: EventChunkKind, sequence: Int, compression: ChunkCompression) -> String {
        let seq = String(format: "%06d", sequence)
        let base: String
        switch kind {
        case .cursor: base = "cursor-\(seq).jsonl"
        case .clicks: base = "clicks-\(seq).jsonl"
        case .keyboard: base = "keyboard-\(seq).jsonl"
        }
        return compression == .zstd ? base + ".zst" : base
    }

    public static func cursorDescriptorFileName(index: Int) -> String {
        String(format: "descriptor-%04d.json", index)
    }

    public static func cursorImageFileName(index: Int) -> String {
        String(format: "descriptor-%04d.png", index)
    }

    /// Suffix for media/chunks still being written; never journaled, never
    /// deleted by recovery (quarantined by rename instead).
    public static let partialSuffix = ".partial"

    /// Resolve a manifest-relative path, rejecting escapes.
    public func resolve(relativePath: String) throws -> URL {
        guard Manifest.isSafeRelativePath(relativePath) else {
            throw ScreenreelError.manifestInvalid(
                path: root.path, reason: "unsafe relative path '\(relativePath)'")
        }
        return root.appendingPathComponent(relativePath)
    }

    /// Package-relative path of a file inside the package, or the absolute
    /// path when it lies outside. Compared under several normalizations:
    /// `standardizedFileURL` rewrites `/private/tmp/…` to `/tmp/…` only once
    /// the path EXISTS, so a root captured before the package was created
    /// and a file URL resolved afterwards used to disagree — and the journal
    /// then carried absolute `segmentOpened` paths that never matched their
    /// commits (validation: `segment.openedNotCommitted` on a clean stop).
    public func relativePath(of url: URL) -> String {
        let pairs: [(URL, URL)] = [
            (root, url),
            (root.standardizedFileURL, url.standardizedFileURL),
            (root.resolvingSymlinksInPath(), url.resolvingSymlinksInPath()),
            (root.standardizedFileURL.resolvingSymlinksInPath(),
             url.standardizedFileURL.resolvingSymlinksInPath()),
        ]
        for (base, target) in pairs {
            let rootPath = base.path + "/"
            let path = target.path
            if path.hasPrefix(rootPath) {
                return String(path.dropFirst(rootPath.count))
            }
        }
        return url.path
    }
}
