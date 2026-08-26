import Foundation

/// Errors thrown by ProjectModel. Every case carries enough context to be
/// actionable in the UI and diagnostic log.
public enum AksError: Error, Sendable, CustomStringConvertible {
    case invalidJSON(String)
    case ioFailed(operation: String, path: String, errno: Int32)
    case notAProject(path: String, reason: String)
    case schemaTooNew(found: Int, supported: Int, path: String)
    case manifestInvalid(path: String, reason: String)
    case journalInvalid(reason: String, atLine: Int)
    case sessionActive(path: String, pid: Int32)
    case assetMissing(path: String)
    case invariantViolated(String)

    public var description: String {
        switch self {
        case .invalidJSON(let why):
            return "Invalid JSON: \(why)"
        case .ioFailed(let op, let path, let err):
            return "I/O failure during \(op) at \(path): \(String(cString: strerror(err))) (errno \(err))"
        case .notAProject(let path, let reason):
            return "Not an Aks project at \(path): \(reason)"
        case .schemaTooNew(let found, let supported, let path):
            return "Project at \(path) uses schema version \(found); this build supports up to \(supported). "
                + "Raw media remains readable under raw/ — use a newer Aks or `aks extract`."
        case .manifestInvalid(let path, let reason):
            return "Manifest at \(path) is invalid: \(reason)"
        case .journalInvalid(let reason, let line):
            return "Journal invalid at line \(line): \(reason)"
        case .sessionActive(let path, let pid):
            return "Project at \(path) is being written by a live session (pid \(pid)). Stop it before recovery."
        case .assetMissing(let path):
            return "Referenced asset is missing: \(path)"
        case .invariantViolated(let why):
            return "Internal invariant violated: \(why)"
        }
    }
}
