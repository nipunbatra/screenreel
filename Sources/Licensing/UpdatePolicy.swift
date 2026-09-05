import Foundation

/// Pure decision logic for the update check, kept out of the app so it can
/// be tested without a network or a bundle.
public enum UpdatePolicy {
    /// Automatic checks run at most this often.
    public static let automaticInterval: TimeInterval = 24 * 60 * 60

    /// Whether an automatic check should run now.
    /// - Parameters:
    ///   - enabled: the "Check for updates automatically" setting.
    ///   - lastCheck: when the last *successful* check completed.
    ///   - now: the current time.
    public static func automaticCheckIsDue(enabled: Bool, lastCheck: Date?, now: Date = Date()) -> Bool {
        guard enabled else { return false }
        guard let lastCheck else { return true }
        // A clock set backwards must not suppress checks for years.
        if lastCheck > now { return true }
        return now.timeIntervalSince(lastCheck) >= automaticInterval
    }

    public enum Outcome: Equatable, Sendable {
        /// The installed build is current (or newer than the latest release).
        case upToDate
        /// A newer release exists and should be offered.
        case updateAvailable(SemanticVersion)
        /// A newer release exists but the user chose "Skip This Version" —
        /// only honored for automatic checks; a manual check still offers it.
        case skipped(SemanticVersion)
        /// The release tag is not a version — nothing sensible to compare.
        case unparseableTag(String)
    }

    /// Compare the installed version against the latest release.
    public static func evaluate(
        installed: SemanticVersion,
        latest: ReleaseInfo,
        skippedVersion: String?,
        manual: Bool
    ) -> Outcome {
        guard let latestVersion = latest.version else { return .unparseableTag(latest.tagName) }
        guard installed < latestVersion else { return .upToDate }
        if !manual, let skipped = skippedVersion.flatMap(SemanticVersion.init), skipped == latestVersion {
            return .skipped(latestVersion)
        }
        return .updateAvailable(latestVersion)
    }
}
