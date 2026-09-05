import CryptoKit
import Foundation

/// Offline Ed25519 verification of license keys.
///
/// Holds any number of public keys so a test key and the production key can
/// coexist, and so a future key rotation can accept keys signed by either
/// generation. Verification needs no network, clock, or account: the payload
/// bytes exactly as received are checked against the signature, then parsed.
public struct LicenseVerifier: Sendable {
    /// Raw 32-byte public keys. Stored as bytes rather than
    /// `Curve25519.Signing.PublicKey` so the verifier is trivially `Sendable`.
    private let publicKeys: [Data]

    public init(publicKeys: [Curve25519.Signing.PublicKey]) {
        self.publicKeys = publicKeys.map(\.rawRepresentation)
    }

    /// Convenience: the production key (plus optional extras).
    public static var production: LicenseVerifier {
        LicenseVerifier(publicKeys: [LicensePublicKeys.production])
    }

    /// Verify and parse a key string.
    public func verify(_ keyString: String) throws(LicenseError) -> License {
        let (payload, signature) = try LicenseKey.parse(keyString)
        let accepted = publicKeys.contains { raw in
            guard let key = try? Curve25519.Signing.PublicKey(rawRepresentation: raw) else { return false }
            return key.isValidSignature(signature, for: payload)
        }
        guard accepted else { throw .signatureMismatch }
        return try License(canonicalJSON: payload)
    }

    /// `Result` form for call sites that prefer not to `try`.
    public func status(of keyString: String?) -> LicenseStatus {
        guard let keyString, !keyString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .unlicensed
        }
        do {
            return .valid(try verify(keyString))
        } catch {
            return .invalid(reason: error)
        }
    }
}

/// Signing side, used by the issuing script's test double and by tests. The
/// production private key never lives in this repository; see
/// `Scripts/make-license.swift`.
public enum LicenseIssuer {
    public static func issue(_ license: License, privateKey: Curve25519.Signing.PrivateKey) throws -> String {
        let payload = try license.canonicalJSON()
        let signature = try privateKey.signature(for: payload)
        return LicenseKey.string(payload: payload, signature: signature)
    }
}

/// Public keys accepted by the shipping app.
public enum LicensePublicKeys {
    /// PLACEHOLDER. This is the public half of a throwaway keypair whose
    /// private half was discarded, so no key can verify against it — every
    /// key is "invalid" until the owner replaces it.
    ///
    /// To go live:
    ///   1. `swift Scripts/make-license.swift --generate-keys ~/secure/screenreel-license`
    ///   2. paste the printed base64 into `productionBase64` below
    ///   3. keep the private key out of Git (docs/DISTRIBUTION.md).
    static let placeholderBase64 = "ILLy9Yf0+bxnDRndrHPrUTMT+7Ri4BxfvYNcXg2TNoc="

    /// Replace with the real production public key (base64 of the 32-byte
    /// raw Ed25519 public key, exactly as printed by `--generate-keys`).
    public static let productionBase64 = placeholderBase64

    /// True until `productionBase64` has been replaced. The license sheet
    /// surfaces this so a build cannot ship silently unable to accept keys.
    public static var isPlaceholder: Bool { productionBase64 == placeholderBase64 }

    public static var production: Curve25519.Signing.PublicKey {
        guard let data = Data(base64Encoded: productionBase64),
            let key = try? Curve25519.Signing.PublicKey(rawRepresentation: data)
        else {
            preconditionFailure("LicensePublicKeys.productionBase64 is not a 32-byte base64 Ed25519 public key")
        }
        return key
    }
}
