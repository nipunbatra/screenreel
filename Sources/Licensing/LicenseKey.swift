import CryptoKit
import Foundation

/// Every distinct way a pasted key can fail, so the UI can say exactly what
/// is wrong instead of "invalid key".
public enum LicenseError: Error, Equatable, Sendable {
    /// Nothing but whitespace was entered.
    case empty
    /// The key does not start with the `SR1-` version prefix.
    case unrecognizedPrefix
    /// The key is too short to contain a payload, separator, and signature.
    case truncated
    /// The character before the signature is not the `-` separator.
    case missingSeparator
    /// The payload is not valid unpadded base64url.
    case payloadNotBase64
    /// The signature is not valid unpadded base64url.
    case signatureNotBase64
    /// The signature decoded to something other than 64 bytes.
    case signatureWrongLength(Int)
    /// No configured public key accepts the signature: the payload was
    /// altered, or the key was issued for a different product/key.
    case signatureMismatch
    /// The payload verified but does not describe a license this app
    /// understands.
    case malformedPayload(String)

    /// One-line, user-facing explanation.
    public var message: String {
        switch self {
        case .empty: return "Paste a license key."
        case .unrecognizedPrefix: return "This is not a \(LicenseKey.prefix) license key."
        case .truncated: return "The key is incomplete — make sure the whole key was pasted."
        case .missingSeparator: return "The key is missing its separator; check that it was pasted whole."
        case .payloadNotBase64: return "The key's payload is corrupted."
        case .signatureNotBase64: return "The key's signature is corrupted."
        case .signatureWrongLength: return "The key's signature has the wrong length."
        case .signatureMismatch: return "The signature does not match — the key was altered or was not issued for this app."
        case .malformedPayload(let detail): return "The key verified but cannot be read: \(detail)."
        }
    }
}

/// Wire format: `SR1-<base64url payload>-<base64url signature>`.
///
/// Both parts are unpadded base64url (RFC 4648 §5). Because `-` is part of
/// the base64url alphabet, the key is parsed from the *end*: an Ed25519
/// signature is always 64 bytes, which is always 86 base64url characters,
/// so the last 86 characters are the signature, the character before them
/// must be `-`, and everything between the prefix and that separator is the
/// payload.
public enum LicenseKey {
    public static let version = "SR1"
    public static let prefix = "SR1-"
    /// 64 signature bytes → ceil(64 * 4 / 3) = 86 base64url characters.
    static let signatureLength = 86

    /// Assemble a key from payload bytes and their signature.
    public static func string(payload: Data, signature: Data) -> String {
        prefix + Base64URL.encode(payload) + "-" + Base64URL.encode(signature)
    }

    /// Split a key into payload and signature bytes without verifying
    /// anything. Whitespace anywhere in the string is ignored so a key that
    /// was line-wrapped by an email client still parses.
    public static func parse(_ raw: String) throws(LicenseError) -> (payload: Data, signature: Data) {
        let key = String(raw.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) })
        guard !key.isEmpty else { throw .empty }
        guard key.hasPrefix(prefix) else { throw .unrecognizedPrefix }
        let body = key.dropFirst(prefix.count)
        // Shortest possible payload is a non-empty base64url string (2 chars).
        guard body.count >= signatureLength + 1 + 2 else { throw .truncated }
        let signaturePart = body.suffix(signatureLength)
        let separatorIndex = body.index(body.endIndex, offsetBy: -(signatureLength + 1))
        guard body[separatorIndex] == "-" else { throw .missingSeparator }
        let payloadPart = body[body.startIndex..<separatorIndex]
        guard let payload = Base64URL.decode(String(payloadPart)) else { throw .payloadNotBase64 }
        guard let signature = Base64URL.decode(String(signaturePart)) else { throw .signatureNotBase64 }
        guard signature.count == 64 else { throw .signatureWrongLength(signature.count) }
        return (payload, signature)
    }
}

/// Unpadded base64url (RFC 4648 §5).
public enum Base64URL {
    public static func encode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    public static func decode(_ string: String) -> Data? {
        // Strict alphabet check first — `Data(base64Encoded:)` silently
        // ignores some invalid input, which would blur error reasons.
        let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
        guard string.allSatisfy(allowed.contains) else { return nil }
        var standard = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = standard.count % 4
        if remainder == 1 { return nil }
        if remainder > 0 { standard += String(repeating: "=", count: 4 - remainder) }
        return Data(base64Encoded: standard)
    }
}
