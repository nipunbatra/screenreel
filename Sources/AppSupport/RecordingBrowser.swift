import Foundation

/// Classification rules for the recordings browser (pure, testable).
public enum RecordingBrowser {

    /// A package that was created by a recording attempt that never
    /// captured anything: state still `recording`, no duration, no raw
    /// screen media, and old enough that it cannot be the session in
    /// progress. Older builds left these behind when capture failed to
    /// start (permission refused); they show as blank cards otherwise.
    public static func isFailedStart(
        state: String?,
        durationNs: Int64?,
        hasScreenMedia: Bool,
        modified: Date,
        now: Date = Date(),
        minimumAgeSeconds: TimeInterval = 120
    ) -> Bool {
        guard state == "recording" || state == nil else { return false }
        guard durationNs == nil || durationNs == 0 else { return false }
        guard !hasScreenMedia else { return false }
        return now.timeIntervalSince(modified) >= minimumAgeSeconds
    }
}
