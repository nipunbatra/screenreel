import Foundation
import Licensing

/// What this running binary knows about itself: the marketing version
/// (`CFBundleShortVersionString`, stamped from the repo's `VERSION` file by
/// `Scripts/make-app.sh`) and the build date (`SRBuildDate`, stamped by the
/// same script). A bare `swift run AksApp` has no Info.plist, so both fall
/// back to values that make the update check and license window honest
/// rather than silently "current".
enum AppBuildInfo {
    static let buildDateKey = "SRBuildDate"

    /// `CFBundleShortVersionString`, or `0.0.0-dev` for an unbundled build.
    static let versionString: String = {
        if let value = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
            !value.isEmpty
        {
            return value
        }
        return "0.0.0-dev"
    }()

    static let version: SemanticVersion = SemanticVersion(versionString) ?? SemanticVersion(0, 0, 0, prerelease: ["dev"])

    static var isDevelopmentBuild: Bool { !version.prerelease.isEmpty && version.prerelease.first == "dev" }

    /// When this build was made. Order of preference: the `SRBuildDate`
    /// Info.plist key (RFC 3339, written at packaging time); the executable's
    /// modification time; now. Used only to decide whether a license's
    /// update window covers this build.
    static let buildDate: Date = {
        if let stamp = Bundle.main.object(forInfoDictionaryKey: buildDateKey) as? String,
            let date = RFC3339.date(from: stamp)
        {
            return date
        }
        if let executable = Bundle.main.executableURL,
            let attributes = try? FileManager.default.attributesOfItem(atPath: executable.path),
            let modified = attributes[.modificationDate] as? Date
        {
            return modified
        }
        return Date()
    }()
}
