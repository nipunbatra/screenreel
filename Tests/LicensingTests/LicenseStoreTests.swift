import CryptoKit
import Foundation
import XCTest

@testable import Licensing

/// Persistence in an isolated `UserDefaults` suite; nothing touches the
/// standard defaults of the machine running the tests.
final class LicenseStoreTests: XCTestCase {

    private var suiteName = ""
    private var defaults: UserDefaults!
    private let signingKey = Curve25519.Signing.PrivateKey()

    override func setUp() {
        super.setUp()
        suiteName = "LicensingTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func makeStore() -> LicenseStore {
        LicenseStore(defaults: defaults, verifier: LicenseVerifier(publicKeys: [signingKey.publicKey]))
    }

    func testUnlicensedByDefault() {
        let store = makeStore()
        XCTAssertNil(store.keyString)
        XCTAssertEqual(store.status, .unlicensed)
        XCTAssertFalse(store.updatesCovered(buildDate: Date()))
    }

    func testSaveValidKeyThenReadBack() throws {
        let store = makeStore()
        let license = License(email: "someone@example.org", tier: .personal)
        let key = try LicenseIssuer.issue(license, privateKey: signingKey)
        let saved = try store.save("  " + key + "\n")
        XCTAssertEqual(saved.email, "someone@example.org")
        XCTAssertEqual(defaults.string(forKey: "license.key"), key, "stored compact, under the documented key")
        XCTAssertEqual(store.status.license?.email, "someone@example.org")
        XCTAssertTrue(store.status.isValid)
        XCTAssertTrue(store.updatesCovered(buildDate: Date()))

        store.clear()
        XCTAssertEqual(store.status, .unlicensed)
    }

    func testInvalidKeyIsNotStored() {
        let store = makeStore()
        XCTAssertThrowsError(try store.save("SR1-nope")) { error in
            XCTAssertEqual(error as? LicenseError, .truncated)
        }
        XCTAssertNil(store.keyString)
        XCTAssertEqual(store.status, .unlicensed)
    }

    func testStoredKeyThatNoLongerVerifiesReportsInvalid() throws {
        // A key accepted by an old public key, then the accepted keys change.
        let oldKey = Curve25519.Signing.PrivateKey()
        let key = try LicenseIssuer.issue(License(email: "x@y.z", tier: .team, seats: 2), privateKey: oldKey)
        defaults.set(key, forKey: LicenseStore.defaultsKey)
        let store = makeStore()
        XCTAssertEqual(store.status, .invalid(reason: .signatureMismatch))
        XCTAssertFalse(store.updatesCovered(buildDate: Date()))
    }

    func testBlankStoredValueIsUnlicensed() {
        defaults.set("   ", forKey: LicenseStore.defaultsKey)
        XCTAssertEqual(makeStore().status, .unlicensed)
    }
}
