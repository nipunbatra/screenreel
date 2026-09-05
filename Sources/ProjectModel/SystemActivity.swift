import Foundation

/// A scoped `ProcessInfo` activity assertion. Without one, macOS App Nap
/// throttles a backgrounded process (timers coalesce, QoS drops) and idle
/// sleep can stop the display or the machine mid-way through a recording or
/// an export — the app hides its window while recording, so it IS a
/// background process for most of a session.
public final class SystemActivity: @unchecked Sendable {
    public enum Kind: Sendable {
        /// Real-time capture: no App Nap, no idle system/display sleep,
        /// latency-critical scheduling.
        case recording
        /// Long CPU/GPU job: no App Nap, no idle system sleep (the display
        /// may sleep).
        case export
        /// Interactive playback in the editor.
        case playback

        var options: ProcessInfo.ActivityOptions {
            switch self {
            case .recording:
                return [.userInitiated, .idleSystemSleepDisabled, .idleDisplaySleepDisabled, .latencyCritical]
            case .export:
                return [.userInitiated, .idleSystemSleepDisabled]
            case .playback:
                return [.userInitiated, .latencyCritical]
            }
        }
    }

    private let lock = NSLock()
    private var token: NSObjectProtocol?

    public init(_ kind: Kind, reason: String) {
        token = ProcessInfo.processInfo.beginActivity(options: kind.options, reason: reason)
    }

    /// Ends the assertion; safe to call more than once. Also ends on deinit.
    public func end() {
        lock.lock()
        let token = self.token
        self.token = nil
        lock.unlock()
        if let token {
            ProcessInfo.processInfo.endActivity(token)
        }
    }

    deinit { end() }
}
