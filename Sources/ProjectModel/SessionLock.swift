import Foundation

/// `session.lock` — an incomplete-session marker, not an OS lock
/// (`docs/PROJECT_FORMAT.md` §2). Its presence means a session did not close
/// cleanly; liveness of the writer is decided from pid + process start marker
/// + heartbeat age, never from file presence alone.
public struct SessionLock: Codable, Sendable, Equatable {
    public var schemaVersion: Int
    public var sessionID: UUID
    public var pid: Int32
    public var processStartMarker: String
    public var createdAt: String
    public var lastCommittedSequence: UInt64
    public var heartbeatAt: String

    public init(
        sessionID: UUID,
        pid: Int32 = ProcessInfo.processInfo.processIdentifier,
        processStartMarker: String = ProcessIdentity.currentStartMarker(),
        createdAt: String = RFC3339.now(),
        lastCommittedSequence: UInt64 = 0,
        heartbeatAt: String = RFC3339.now()
    ) {
        self.schemaVersion = ProjectSchema.currentVersion
        self.sessionID = sessionID
        self.pid = pid
        self.processStartMarker = processStartMarker
        self.createdAt = createdAt
        self.lastCommittedSequence = lastCommittedSequence
        self.heartbeatAt = heartbeatAt
    }

    /// Heartbeat rewrites pass `durable: false`: the lock is advisory
    /// (liveness comes from pid + start marker + heartbeat age), so flushing
    /// the drive cache twice a second would buy nothing.
    public func write(to url: URL, durable: Bool = true) throws {
        try AtomicFile.writeJSON(self, to: url, durable: durable)
    }

    public static func read(from url: URL) throws -> SessionLock {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(SessionLock.self, from: data)
    }

    /// True when the recorded pid is alive *and* is the same process
    /// incarnation that created the lock (guards against pid reuse).
    public func writerIsAlive() -> Bool {
        guard kill(pid, 0) == 0 || errno == EPERM else { return false }
        guard let marker = ProcessIdentity.startMarker(forPID: pid) else { return false }
        return marker == processStartMarker
    }
}

/// Identifies a process incarnation as "pid started at boot-relative time",
/// so a reused pid after reboot or process churn is never mistaken for the
/// original writer.
public enum ProcessIdentity {
    public static func currentStartMarker() -> String {
        startMarker(forPID: ProcessInfo.processInfo.processIdentifier) ?? "unknown"
    }

    public static func startMarker(forPID pid: Int32) -> String? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        let result = sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0)
        guard result == 0, size > 0 else { return nil }
        let start = info.kp_proc.p_starttime
        return "\(pid):\(start.tv_sec).\(start.tv_usec)"
    }
}
