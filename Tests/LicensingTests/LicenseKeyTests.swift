import CryptoKit
import Foundation
import XCTest

@testable import Licensing

/// Sign/verify round trips, tamper detection, and one distinct error per
/// malformed input. Every key here is signed by a keypair generated inside
/// the test — no private key exists in the repository.
final class LicenseKeyTests: XCTestCase {

    private let signingKey = Curve25519.Signing.PrivateKey()
    private var verifier: LicenseVerifier { LicenseVerifier(publicKeys: [signingKey.publicKey]) }

    private func sample(updatesUntil: Date? = nil) -> License {
        License(
            id: UUID(uuidString: "0B9F2A4C-6F2B-4E1D-9C3A-1F2E3D4C5B6A")!,
            email: "someone@example.org",
            tier: .personal,
            seats: 1,
            issuedAt: RFC3339.date(from: "2026-09-05T10:00:00Z")!,
            updatesUntil: updatesUntil)
    }

    // MARK: Round trip

    func testSignVerifyRoundTrip() throws {
        let until = RFC3339.date(from: "2027-09-05T23:59:59Z")!
        let key = try LicenseIssuer.issue(sample(updatesUntil: until), privateKey: signingKey)
        XCTAssertTrue(key.hasPrefix("SR1-"))
        XCTAssertFalse(key.contains("="), "unpadded base64url")
        XCTAssertFalse(key.contains("+"))
        XCTAssertFalse(key.contains("/"))

        let license = try verifier.verify(key)
        XCTAssertEqual(license, sample(updatesUntil: until))
    }

    func testTeamTierAndSeatsRoundTrip() throws {
        let team = License(email: "lab@example.org", tier: .team, seats: 12)
        let key = try LicenseIssuer.issue(team, privateKey: signingKey)
        let license = try verifier.verify(key)
        XCTAssertEqual(license.tier, .team)
        XCTAssertEqual(license.seats, 12)
        XCTAssertNil(license.updatesUntil)
        // Sub-second precision is dropped by the canonical form.
        XCTAssertEqual(license.issuedAt.timeIntervalSince1970, team.issuedAt.timeIntervalSince1970.rounded(.down))
    }

    /// base64url uses `-`, which is also the key's separator; the parser
    /// must not be confused by payloads or signatures that contain it.
    func testManyRandomKeysParseDespiteDashesInBase64() throws {
        var sawDashInSignature = false
        for index in 0..<200 {
            let license = License(email: "user\(index)@example.org", tier: index % 2 == 0 ? .personal : .team, seats: index + 1)
            let key = try LicenseIssuer.issue(license, privateKey: signingKey)
            sawDashInSignature = sawDashInSignature || key.suffix(86).contains("-")
            XCTAssertEqual(try verifier.verify(key), license.canonicalized())
        }
        XCTAssertTrue(sawDashInSignature, "expected at least one signature containing '-'")
    }

    /// Printable-ASCII JSON rarely base64-encodes to `-` (sextet 62 needs a
    /// byte ending in binary 11 followed by `~`), so aim for it: one of these
    /// emails puts `o~` at the alignment that produces a `-` in the payload.
    func testPayloadContainingDashParses() throws {
        var found = false
        for padding in 0..<3 {
            let email = String(repeating: "a", count: padding) + "o~@example.org"
            let license = License(email: email, tier: .personal)
            let key = try LicenseIssuer.issue(license, privateKey: signingKey)
            let payloadPart = key.dropFirst(4).dropLast(87)
            if payloadPart.contains("-") {
                found = true
                XCTAssertEqual(try verifier.verify(key).email, email)
            }
        }
        XCTAssertTrue(found, "expected a payload containing '-' — the alignment reasoning above is wrong if this fails")
    }

    func testWhitespaceAndLineWrapsAreIgnored() throws {
        let key = try LicenseIssuer.issue(sample(), privateKey: signingKey)
        let head = String(key.prefix(20))
        let middle = String(key.dropFirst(20).prefix(30))
        let tail = String(key.dropFirst(50))
        let wrapped = "  \(head)\n\(middle)\r\n \(tail)\n"
        XCTAssertEqual(try verifier.verify(wrapped), sample())
    }

    func testMultiplePublicKeysCoexist() throws {
        let production = Curve25519.Signing.PrivateKey()
        let both = LicenseVerifier(publicKeys: [signingKey.publicKey, production.publicKey])
        let testKey = try LicenseIssuer.issue(sample(), privateKey: signingKey)
        let productionKey = try LicenseIssuer.issue(sample(), privateKey: production)
        XCTAssertNoThrow(try both.verify(testKey))
        XCTAssertNoThrow(try both.verify(productionKey))
    }

    // MARK: Rejections

    func testTamperedPayloadIsRejected() throws {
        let key = try LicenseIssuer.issue(sample(), privateKey: signingKey)
        // Re-sign nothing: swap the payload for a different, well-formed one
        // while keeping the original signature.
        let (_, signature) = try LicenseKey.parse(key)
        var forged = sample()
        forged.tier = .team
        forged.seats = 500
        let tampered = LicenseKey.string(payload: try forged.canonicalJSON(), signature: signature)
        XCTAssertThrowsError(try verifier.verify(tampered)) { error in
            XCTAssertEqual(error as? LicenseError, .signatureMismatch)
        }
    }

    func testSingleFlippedCharacterIsRejected() throws {
        let key = try LicenseIssuer.issue(sample(), privateKey: signingKey)
        // Flip a character inside the payload region.
        var characters = Array(key)
        let index = 12
        characters[index] = characters[index] == "A" ? "B" : "A"
        let flipped = String(characters)
        XCTAssertThrowsError(try verifier.verify(flipped)) { error in
            XCTAssertEqual(error as? LicenseError, .signatureMismatch)
        }
    }

    func testWrongPublicKeyIsRejected() throws {
        let key = try LicenseIssuer.issue(sample(), privateKey: signingKey)
        let other = LicenseVerifier(publicKeys: [Curve25519.Signing.PrivateKey().publicKey])
        XCTAssertThrowsError(try other.verify(key)) { error in
            XCTAssertEqual(error as? LicenseError, .signatureMismatch)
        }
        let none = LicenseVerifier(publicKeys: [])
        XCTAssertThrowsError(try none.verify(key)) { error in
            XCTAssertEqual(error as? LicenseError, .signatureMismatch)
        }
    }

    func testPlaceholderProductionKeyAcceptsNothing() throws {
        XCTAssertTrue(LicensePublicKeys.isPlaceholder, "flip this expectation when the real key is installed")
        let key = try LicenseIssuer.issue(sample(), privateKey: signingKey)
        XCTAssertThrowsError(try LicenseVerifier.production.verify(key))
    }

    func testMalformedStringsFailWithDistinctReasons() throws {
        let good = try LicenseIssuer.issue(sample(), privateKey: signingKey)
        let signature86 = String(good.suffix(86))

        func reason(_ string: String) -> LicenseError? {
            do {
                _ = try verifier.verify(string)
                return nil
            } catch {
                return error
            }
        }

        XCTAssertEqual(reason(""), .empty)
        XCTAssertEqual(reason("   \n"), .empty)
        XCTAssertEqual(reason("SR2-abc"), .unrecognizedPrefix)
        XCTAssertEqual(reason("hello world"), .unrecognizedPrefix)
        XCTAssertEqual(reason("SR1-abc"), .truncated)
        XCTAssertEqual(reason(String(good.prefix(60))), .truncated)
        // Separator replaced by a base64url character.
        let beforeSeparator = String(good.dropLast(87))
        let noSeparator = "\(beforeSeparator)x\(signature86)"
        XCTAssertEqual(reason(noSeparator), .missingSeparator)
        // Payload with characters outside the base64url alphabet.
        XCTAssertEqual(reason("SR1-ab$cd!ef-" + signature86), .payloadNotBase64)
        // Signature with invalid characters.
        XCTAssertEqual(reason("SR1-abcd-" + String(repeating: "*", count: 86)), .signatureNotBase64)
        // 86 valid characters that do not decode to 64 bytes is impossible
        // (86 chars → 64 bytes), so exercise the length check directly.
        XCTAssertEqual(
            try? LicenseKey.parse("SR1-abcd-" + String(repeating: "A", count: 86)).signature.count, 64)
        // Verified payload that is not a license.
        let junkPayload = Data("[1,2,3]".utf8)
        let junkKey = LicenseKey.string(payload: junkPayload, signature: try signingKey.signature(for: junkPayload))
        XCTAssertEqual(reason(junkKey), .malformedPayload("payload is not a JSON object"))
        let unknownTier = Data(#"{"email":"a@b","id":"0B9F2A4C-6F2B-4E1D-9C3A-1F2E3D4C5B6A","issuedAt":"2026-01-01T00:00:00Z","tier":"enterprise"}"#.utf8)
        let unknownTierKey = LicenseKey.string(payload: unknownTier, signature: try signingKey.signature(for: unknownTier))
        XCTAssertEqual(reason(unknownTierKey), .malformedPayload("unknown tier 'enterprise'"))
        let badSeats = Data(#"{"email":"a@b","id":"0B9F2A4C-6F2B-4E1D-9C3A-1F2E3D4C5B6A","issuedAt":"2026-01-01T00:00:00Z","seats":0,"tier":"team"}"#.utf8)
        let badSeatsKey = LicenseKey.string(payload: badSeats, signature: try signingKey.signature(for: badSeats))
        XCTAssertEqual(reason(badSeatsKey), .malformedPayload("'seats' must be a positive integer"))
        let badDate = Data(#"{"email":"a@b","id":"0B9F2A4C-6F2B-4E1D-9C3A-1F2E3D4C5B6A","issuedAt":"yesterday","tier":"personal"}"#.utf8)
        let badDateKey = LicenseKey.string(payload: badDate, signature: try signingKey.signature(for: badDate))
        XCTAssertEqual(reason(badDateKey), .malformedPayload("missing or invalid 'issuedAt'"))

        // Every reason has a non-empty user-facing message.
        for error: LicenseError in [
            .empty, .unrecognizedPrefix, .truncated, .missingSeparator, .payloadNotBase64,
            .signatureNotBase64, .signatureWrongLength(3), .signatureMismatch, .malformedPayload("x"),
        ] {
            XCTAssertFalse(error.message.isEmpty)
        }
    }

    func testSignatureWrongLengthIsDetected() throws {
        // Build a key whose "signature" region is 86 chars but the parse
        // path is asked to handle a signature that is not 64 bytes: the only
        // way is a base64url string of 86 chars that decodes to 64 bytes, so
        // instead cover the decoder contract on its own.
        XCTAssertEqual(Base64URL.decode(String(repeating: "A", count: 86))?.count, 64)
        XCTAssertEqual(Base64URL.decode("AAAA")?.count, 3)
        XCTAssertNil(Base64URL.decode("A"), "a single trailing character can never be valid")
        XCTAssertNil(Base64URL.decode("AB=="), "padding is not part of the alphabet")
    }

    func testBase64URLRoundTripsArbitraryBytes() {
        var generator = SystemRandomNumberGenerator()
        for length in [0, 1, 2, 3, 4, 31, 32, 63, 64, 100] {
            let bytes = Data((0..<length).map { _ in UInt8.random(in: 0...255, using: &generator) })
            let encoded = Base64URL.encode(bytes)
            XCTAssertFalse(encoded.contains("="))
            XCTAssertEqual(Base64URL.decode(encoded), bytes, "length \(length)")
        }
    }

    // MARK: updatesUntil

    func testUpdatesUntilComparison() throws {
        let until = RFC3339.date(from: "2027-09-05T23:59:59Z")!
        let license = sample(updatesUntil: until)
        XCTAssertTrue(license.updatesCovered(buildDate: RFC3339.date(from: "2026-09-05T00:00:00Z")!))
        XCTAssertTrue(license.updatesCovered(buildDate: until), "inclusive at the boundary")
        XCTAssertFalse(license.updatesCovered(buildDate: until.addingTimeInterval(1)))
        XCTAssertFalse(license.updatesCovered(buildDate: RFC3339.date(from: "2030-01-01T00:00:00Z")!))

        let perpetual = sample(updatesUntil: nil)
        XCTAssertTrue(perpetual.updatesCovered(buildDate: RFC3339.date(from: "2099-01-01T00:00:00Z")!))

        XCTAssertFalse(LicenseStatus.unlicensed.updatesCovered(buildDate: Date()))
        XCTAssertFalse(LicenseStatus.invalid(reason: .empty).updatesCovered(buildDate: Date()))
        XCTAssertTrue(LicenseStatus.valid(perpetual).updatesCovered(buildDate: Date()))
    }

    // MARK: Canonical JSON

    func testCanonicalJSONIsStableSortedAndCompact() throws {
        let until = RFC3339.date(from: "2027-09-05T23:59:59Z")!
        let license = sample(updatesUntil: until)
        let first = try license.canonicalJSON()
        let second = try license.canonicalJSON()
        XCTAssertEqual(first, second)
        let text = String(decoding: first, as: UTF8.self)
        XCTAssertEqual(
            text,
            #"{"email":"someone@example.org","id":"0b9f2a4c-6f2b-4e1d-9c3a-1f2e3d4c5b6a","issuedAt":"2026-09-05T10:00:00Z","seats":1,"tier":"personal","updatesUntil":"2027-09-05T23:59:59Z"}"#
        )
        XCTAssertFalse(text.contains(" "))
        XCTAssertFalse(text.contains("\n"))

        // Optional field omitted, not null.
        let perpetual = String(decoding: try sample().canonicalJSON(), as: UTF8.self)
        XCTAssertFalse(perpetual.contains("updatesUntil"))
        XCTAssertFalse(perpetual.contains("null"))

        // Re-issuing the same license yields the same payload bytes. The
        // signature bytes may differ (CryptoKit's Ed25519 signing is
        // randomized), but every issuance must verify.
        let reissuedA = try LicenseIssuer.issue(license, privateKey: signingKey)
        let reissuedB = try LicenseIssuer.issue(license, privateKey: signingKey)
        XCTAssertEqual(try LicenseKey.parse(reissuedA).payload, try LicenseKey.parse(reissuedB).payload)
        XCTAssertEqual(try verifier.verify(reissuedA), try verifier.verify(reissuedB))

        // Slashes in an email are not escaped.
        let slashy = License(email: "a/b@example.org", tier: .personal)
        XCTAssertTrue(String(decoding: try slashy.canonicalJSON(), as: UTF8.self).contains("a/b@example.org"))
    }

    func testPayloadAcceptsAnyKeyOrderAndUnknownKeys() throws {
        let json = #"{"tier":"team","future":"ignored","seats":3,"issuedAt":"2026-09-05T10:00:00Z","email":"x@y.z","id":"0B9F2A4C-6F2B-4E1D-9C3A-1F2E3D4C5B6A"}"#
        let license = try License(canonicalJSON: Data(json.utf8))
        XCTAssertEqual(license.tier, .team)
        XCTAssertEqual(license.seats, 3)
        XCTAssertEqual(license.email, "x@y.z")
        XCTAssertEqual(license.id.uuidString, "0B9F2A4C-6F2B-4E1D-9C3A-1F2E3D4C5B6A")
    }

    func testSeatsDefaultsToOneWhenAbsent() throws {
        let json = #"{"email":"x@y.z","id":"0B9F2A4C-6F2B-4E1D-9C3A-1F2E3D4C5B6A","issuedAt":"2026-09-05T10:00:00Z","tier":"personal"}"#
        XCTAssertEqual(try License(canonicalJSON: Data(json.utf8)).seats, 1)
    }
}

extension License {
    /// The license as it will read back after a canonical round trip
    /// (whole-second dates).
    func canonicalized() -> License {
        var copy = self
        copy.issuedAt = RFC3339.date(from: RFC3339.string(from: issuedAt))!
        copy.updatesUntil = updatesUntil.map { RFC3339.date(from: RFC3339.string(from: $0))! }
        return copy
    }
}
