import Foundation
import Licensing
import Observation

/// The app's view of its license.
///
/// NOTHING IS GATED YET. `isLicensed` exists so the owner can decide later
/// what (if anything) a license unlocks — every feature works identically
/// with or without one today. When a gate is introduced, read it from here
/// (not from `LicenseStore` directly) so tests and the license window see
/// the same answer.
@MainActor
@Observable
final class Entitlements {
    static let shared = Entitlements()

    private let store: LicenseStore
    private(set) var status: LicenseStatus

    init(store: LicenseStore = LicenseStore()) {
        self.store = store
        status = store.status
    }

    /// True when a key that verifies against an accepted public key is
    /// installed. Currently informational only (see the type comment).
    var isLicensed: Bool { status.isValid }

    var license: License? { status.license }

    /// Whether the license's update window covers the running build.
    /// Informational only — updates are not withheld on this basis today.
    var updatesCovered: Bool { status.updatesCovered(buildDate: AppBuildInfo.buildDate) }

    /// Re-read the stored key (e.g. after the accepted public keys change).
    func refresh() {
        status = store.status
    }

    /// Validate and persist a pasted key. Throws the precise reason on
    /// failure and leaves the previous key untouched.
    @discardableResult
    func apply(key: String) throws(LicenseError) -> License {
        let license = try store.save(key)
        status = store.status
        return license
    }

    func removeLicense() {
        store.clear()
        status = store.status
    }
}
