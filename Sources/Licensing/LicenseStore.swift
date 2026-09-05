import Foundation

/// What the app knows about its license right now.
public enum LicenseStatus: Equatable, Sendable {
    case unlicensed
    case valid(License)
    case invalid(reason: LicenseError)

    public var license: License? {
        if case .valid(let license) = self { return license }
        return nil
    }

    public var isValid: Bool { license != nil }

    /// Whether a build made on `buildDate` is covered. Only a valid license
    /// covers anything.
    public func updatesCovered(buildDate: Date) -> Bool {
        license?.updatesCovered(buildDate: buildDate) ?? false
    }
}

/// Persists the pasted key string and derives ``LicenseStatus`` from it on
/// demand. The key itself is the source of truth — nothing derived is
/// cached to disk, so replacing the public key or fixing a parser bug
/// re-evaluates every installed key on next launch.
public struct LicenseStore {
    public static let defaultsKey = "license.key"

    private let defaults: UserDefaults
    public let verifier: LicenseVerifier

    public init(defaults: UserDefaults = .standard, verifier: LicenseVerifier = .production) {
        self.defaults = defaults
        self.verifier = verifier
    }

    /// The stored key string, if any (may be invalid).
    public var keyString: String? {
        defaults.string(forKey: Self.defaultsKey)
    }

    public var status: LicenseStatus {
        verifier.status(of: keyString)
    }

    /// Validate and persist. The key is stored only when it verifies, so the
    /// stored state is never "invalid" unless the accepted keys change
    /// underneath it.
    @discardableResult
    public func save(_ keyString: String) throws(LicenseError) -> License {
        let license = try verifier.verify(keyString)
        let compact = String(keyString.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) })
        defaults.set(compact, forKey: Self.defaultsKey)
        return license
    }

    public func clear() {
        defaults.removeObject(forKey: Self.defaultsKey)
    }

    public func updatesCovered(buildDate: Date) -> Bool {
        status.updatesCovered(buildDate: buildDate)
    }
}
