import AppKit
import Foundation
import Licensing
import Observation

/// Checks GitHub Releases for a newer version.
///
/// This is the app's ONLY network call. It sends one GET to
/// `Branding.latestReleaseAPIURL` (api.github.com) with no identifiers
/// beyond a `User-Agent` naming the app and its version; nothing about the
/// user, the machine, or the projects is transmitted. Automatic checks run
/// at most once per 24 hours and can be switched off (`updates.automatic`).
@MainActor
@Observable
final class UpdateChecker {
    static let shared = UpdateChecker()

    static let automaticKey = "updates.automatic"
    static let lastCheckKey = "updates.lastCheck"
    static let skippedVersionKey = "updates.skippedVersion"
    static let requestTimeout: TimeInterval = 10
    /// Delay after launch before the first automatic check, so it never
    /// competes with permission prompts or a recording being started.
    static let launchDelay: Duration = .seconds(8)
    /// Retry interval when an update is found while a recording is running.
    static let busyRetry: Duration = .seconds(600)

    private let defaults: UserDefaults
    private(set) var isChecking = false
    private var automaticTask: Task<Void, Never>?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [Self.automaticKey: true])
    }

    var automaticEnabled: Bool {
        get { defaults.bool(forKey: Self.automaticKey) }
        set { defaults.set(newValue, forKey: Self.automaticKey) }
    }

    var lastCheck: Date? {
        get { defaults.object(forKey: Self.lastCheckKey) as? Date }
        set { defaults.set(newValue, forKey: Self.lastCheckKey) }
    }

    var skippedVersion: String? {
        get { defaults.string(forKey: Self.skippedVersionKey) }
        set { defaults.set(newValue, forKey: Self.skippedVersionKey) }
    }

    // MARK: Entry points

    /// "Check for Updates…": always talks to the network, always reports.
    func checkNow() {
        guard !isChecking else { return }
        Task { await run(manual: true) }
    }

    /// Called once at launch. Waits a few seconds, then runs a silent check
    /// if the setting is on and the last successful check is older than
    /// `UpdatePolicy.automaticInterval`.
    func scheduleAutomaticCheck() {
        automaticTask?.cancel()
        automaticTask = Task { [weak self] in
            try? await Task.sleep(for: Self.launchDelay)
            guard let self, !Task.isCancelled else { return }
            guard UpdatePolicy.automaticCheckIsDue(enabled: automaticEnabled, lastCheck: lastCheck) else { return }
            await run(manual: false)
        }
    }

    // MARK: Work

    private func run(manual: Bool) async {
        isChecking = true
        defer { isChecking = false }
        let release: ReleaseInfo
        do {
            release = try await fetchLatestRelease()
        } catch {
            if manual { presentFailure(error) }
            return
        }
        lastCheck = Date()
        let outcome = UpdatePolicy.evaluate(
            installed: AppBuildInfo.version, latest: release,
            skippedVersion: skippedVersion, manual: manual)
        switch outcome {
        case .upToDate:
            if manual { presentUpToDate(latest: release) }
        case .skipped:
            break
        case .unparseableTag(let tag):
            if manual { presentFailure(UpdateCheckError.unparseableTag(tag)) }
        case .updateAvailable(let version):
            if !manual && !isSafeToInterrupt {
                // Recording in progress: do not steal focus. Try again later.
                automaticTask = Task { [weak self] in
                    try? await Task.sleep(for: Self.busyRetry)
                    guard let self, !Task.isCancelled, isSafeToInterrupt else { return }
                    presentUpdate(version: version, release: release)
                }
                return
            }
            presentUpdate(version: version, release: release)
        }
    }

    /// One request, ten-second timeout, no caching, no cookies.
    func fetchLatestRelease() async throws -> ReleaseInfo {
        var request = URLRequest(url: Branding.latestReleaseAPIURL)
        request.timeoutInterval = Self.requestTimeout
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("\(Branding.displayName)/\(AppBuildInfo.versionString) (update check)", forHTTPHeaderField: "User-Agent")

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = Self.requestTimeout
        configuration.timeoutIntervalForResource = Self.requestTimeout
        configuration.waitsForConnectivity = false
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw UpdateCheckError.badResponse }
        switch http.statusCode {
        case 200: break
        case 404: throw UpdateCheckError.noReleases
        default: throw UpdateCheckError.httpStatus(http.statusCode)
        }
        return try ReleaseInfo(githubJSON: data)
    }

    /// False while the floating recording HUD (a non-activating panel) is
    /// showing — an alert then would land on top of the take.
    private var isSafeToInterrupt: Bool {
        !NSApp.windows.contains { window in
            window is NSPanel && window.isVisible && window.styleMask.contains(.nonactivatingPanel)
        }
    }

    // MARK: Alerts

    private func presentUpdate(version: SemanticVersion, release: ReleaseInfo) {
        let alert = NSAlert()
        alert.messageText = "\(Branding.displayName) \(version) is available"
        var info = "You have \(AppBuildInfo.versionString)."
        if AppBuildInfo.isDevelopmentBuild {
            info += " (This is an unpackaged development build.)"
        }
        if let notes = Self.summary(of: release.body) {
            info += "\n\n" + notes
        }
        info += "\n\nDownload opens the release in your browser; the app does not update itself."
        alert.informativeText = info
        alert.addButton(withTitle: "Download")
        alert.addButton(withTitle: "Later")
        alert.addButton(withTitle: "Skip This Version")
        NSApp.activate()
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            NSWorkspace.shared.open(release.downloadURL)
        case .alertThirdButtonReturn:
            skippedVersion = version.description
        default:
            break
        }
    }

    private func presentUpToDate(latest: ReleaseInfo) {
        let alert = NSAlert()
        alert.messageText = "You're up to date"
        var info = "\(Branding.displayName) \(AppBuildInfo.versionString) is the newest version"
        if let latestVersion = latest.version, latestVersion < AppBuildInfo.version {
            info = "\(Branding.displayName) \(AppBuildInfo.versionString) is newer than the latest release (\(latestVersion))"
        }
        alert.informativeText = info + "."
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func presentFailure(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "Couldn't check for updates"
        alert.informativeText = (error as? UpdateCheckError)?.message ?? error.localizedDescription
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Open Releases Page")
        if alert.runModal() == .alertSecondButtonReturn {
            NSWorkspace.shared.open(Branding.releasesURL)
        }
    }

    /// First few non-heading lines of the release notes, for the alert.
    static func summary(of body: String?, maxLines: Int = 6, maxCharacters: Int = 400) -> String? {
        guard let body else { return nil }
        let lines = body
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
            .prefix(maxLines)
        guard !lines.isEmpty else { return nil }
        var text = lines.joined(separator: "\n")
        if text.count > maxCharacters {
            text = String(text.prefix(maxCharacters)) + "…"
        }
        return text
    }
}

enum UpdateCheckError: Error {
    case badResponse
    case noReleases
    case httpStatus(Int)
    case unparseableTag(String)

    var message: String {
        switch self {
        case .badResponse: return "GitHub returned an unexpected response."
        case .noReleases: return "No releases have been published yet."
        case .httpStatus(let code): return "GitHub responded with HTTP \(code)."
        case .unparseableTag(let tag): return "The latest release is tagged “\(tag)”, which is not a version number."
        }
    }
}
