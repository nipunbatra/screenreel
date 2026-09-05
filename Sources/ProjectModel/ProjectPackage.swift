import Foundation

/// Creation and loading of `.screenreel` packages. Creation follows the durable
/// write order from `docs/TECHNICAL_DESIGN.md` §3: directories and
/// `session.lock` first, then the initial manifest atomically, then the
/// journal's `sessionCreated` record.
public enum ProjectPackage {

    public struct Created: Sendable {
        public let layout: ProjectLayout
        public let manifestStore: ManifestStore
        public let journal: JournalWriter
        public let sessionID: UUID
    }

    public static func create(
        at url: URL,
        clock: ClockAnchor,
        capture: JSONValue? = nil
    ) async throws -> Created {
        let layout = ProjectLayout(root: url)
        let fm = FileManager.default
        guard !fm.fileExists(atPath: url.path) else {
            throw ScreenreelError.ioFailed(operation: "create project", path: url.path, errno: EEXIST)
        }
        for dir in layout.initialDirectories {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }

        let sessionID = UUID()
        try SessionLock(sessionID: sessionID).write(to: layout.sessionLockURL)

        let manifest = Manifest(state: .recording, clock: clock, capture: capture)
        let store = ManifestStore(layout: layout, manifest: manifest)
        try await store.saveInitial()

        let journal = try JournalWriter(creatingAt: layout.journalURL)
        try await journal.append(
            type: .sessionCreated,
            timeNs: 0,
            payload: JournalPayload.sessionCreated(manifest: manifest))
        try AtomicFile.syncDirectory(url)
        return Created(layout: layout, manifestStore: store, journal: journal, sessionID: sessionID)
    }

    public struct Loaded: Sendable {
        public let layout: ProjectLayout
        public let manifest: Manifest
        public let journal: JournalScan
        public let sessionLock: SessionLock?
    }

    /// Read-only load for validation/inspection. Never mutates anything.
    public static func load(at url: URL) throws -> Loaded {
        let layout = ProjectLayout(root: url)
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else {
            throw ScreenreelError.notAProject(path: url.path, reason: "no such directory")
        }
        guard fm.fileExists(atPath: layout.manifestURL.path) else {
            throw ScreenreelError.notAProject(path: url.path, reason: "manifest.json missing")
        }
        let manifestData = try Data(contentsOf: layout.manifestURL)
        let manifest = try Manifest.decode(from: manifestData, path: layout.manifestURL.path)
        let journal = try JournalReader.scan(url: layout.journalURL)
        let lock = try? SessionLock.read(from: layout.sessionLockURL)
        return Loaded(layout: layout, manifest: manifest, journal: journal, sessionLock: lock)
    }
}
