import CryptoKit
import Foundation
import XCTest

@testable import Licensing

/// `Scripts/make-license.swift` cannot import this module, so it re-implements
/// the wire format by hand. This fixture — a key the script issued with a
/// throwaway keypair whose private half was discarded after issuing — pins
/// the two implementations together: if either side changes the format, this
/// test fails. Regenerate both constants with the commands in
/// docs/DISTRIBUTION.md if the format is changed deliberately.
final class ScriptCompatibilityTests: XCTestCase {

    /// `swift Scripts/make-license.swift --generate-keys <dir>` (public half).
    private let fixturePublicKeyBase64 = "2yDKzfh+g1zfX2eNFSF+TkEFJATDSqUXltFZ3i7qW5U="

    /// `swift Scripts/make-license.swift --issue --key … --email fixture@example.org
    ///   --tier team --seats 3 --updates-until 2027-09-05
    ///   --id 8E0C2A2F-2B0B-4B2B-9C1E-5D8B0A2F1C3D --issued-at 2026-09-05T12:00:00Z`
    private let fixtureKey = "SR1-eyJlbWFpbCI6ImZpeHR1cmVAZXhhbXBsZS5vcmciLCJpZCI6IjhlMGMyYTJmLTJiMGItNGIyYi05YzFlLTVkOGIwYTJmMWMzZCIsImlzc3VlZEF0IjoiMjAyNi0wOS0wNVQxMjowMDowMFoiLCJzZWF0cyI6MywidGllciI6InRlYW0iLCJ1cGRhdGVzVW50aWwiOiIyMDI3LTA5LTA1VDIzOjU5OjU5WiJ9-Mm_haDhfhrPrHuNQmkJNLzgdBF74Pz81MoEIDevQCGRUVaZTt_LqcNrKPCiDv9DIu5V93Y9BQMfCwwcf1alxCA"

    private var verifier: LicenseVerifier {
        let key = try! Curve25519.Signing.PublicKey(rawRepresentation: Data(base64Encoded: fixturePublicKeyBase64)!)
        return LicenseVerifier(publicKeys: [key])
    }

    func testKeyIssuedByScriptVerifiesAndParses() throws {
        let license = try verifier.verify(fixtureKey)
        XCTAssertEqual(license.email, "fixture@example.org")
        XCTAssertEqual(license.tier, .team)
        XCTAssertEqual(license.seats, 3)
        XCTAssertEqual(license.id.uuidString, "8E0C2A2F-2B0B-4B2B-9C1E-5D8B0A2F1C3D")
        XCTAssertEqual(license.issuedAt, RFC3339.date(from: "2026-09-05T12:00:00Z"))
        XCTAssertEqual(license.updatesUntil, RFC3339.date(from: "2027-09-05T23:59:59Z"),
                       "--updates-until is inclusive of the whole day")
    }

    /// The library's canonical encoding of the parsed license must reproduce
    /// the script's payload byte for byte — that is what makes the signature
    /// portable between the two.
    func testLibraryCanonicalFormMatchesScriptPayload() throws {
        let license = try verifier.verify(fixtureKey)
        let (payload, _) = try LicenseKey.parse(fixtureKey)
        XCTAssertEqual(try license.canonicalJSON(), payload)
    }

    func testFixtureKeyIsRejectedByOtherKeys() {
        XCTAssertThrowsError(try LicenseVerifier.production.verify(fixtureKey))
        XCTAssertThrowsError(try LicenseVerifier(publicKeys: [Curve25519.Signing.PrivateKey().publicKey]).verify(fixtureKey))
    }
}
