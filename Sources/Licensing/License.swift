import Foundation

/// The tier a license was issued for. Unknown tiers are rejected at parse
/// time so an older app never silently treats a key it does not understand
/// as valid.
public enum LicenseTier: String, Codable, Sendable, CaseIterable {
    case personal
    case team
}

/// The signed payload of a license key.
///
/// A license is perpetual: once valid it stays valid. `updatesUntil` bounds
/// which *builds* it entitles the holder to — the app compares its own build
/// date against it (see ``updatesCovered(buildDate:)``). A `nil`
/// `updatesUntil` means every build is covered.
///
/// The JSON form is canonical (sorted keys, no whitespace, RFC 3339 dates in
/// UTC) so that issuing the same license twice produces byte-identical
/// payloads, and so the issuing script and this module agree on what is
/// signed. (Signature bytes themselves may differ between issuances —
/// CryptoKit's Ed25519 signing is randomized — which is harmless.)
public struct License: Equatable, Sendable {
    public var id: UUID
    public var email: String
    public var tier: LicenseTier
    public var seats: Int
    public var issuedAt: Date
    public var updatesUntil: Date?

    public init(
        id: UUID = UUID(),
        email: String,
        tier: LicenseTier,
        seats: Int = 1,
        issuedAt: Date = Date(),
        updatesUntil: Date? = nil
    ) {
        self.id = id
        self.email = email
        self.tier = tier
        self.seats = seats
        self.issuedAt = issuedAt
        self.updatesUntil = updatesUntil
    }

    /// Whether a build made on `buildDate` is covered by this license's
    /// update window. Perpetual licenses (`updatesUntil == nil`) cover every
    /// build; otherwise a build is covered when it was made on or before the
    /// `updatesUntil` instant.
    public func updatesCovered(buildDate: Date) -> Bool {
        guard let updatesUntil else { return true }
        return buildDate <= updatesUntil
    }
}

// MARK: - Canonical JSON

extension License {
    /// Field names as they appear in the signed payload. Kept explicit so the
    /// issuing script (`Scripts/make-license.swift`), which cannot import this
    /// module, can mirror them exactly.
    enum Field {
        static let id = "id"
        static let email = "email"
        static let tier = "tier"
        static let seats = "seats"
        static let issuedAt = "issuedAt"
        static let updatesUntil = "updatesUntil"
    }

    /// Canonical payload bytes: JSON object with keys sorted, no whitespace,
    /// dates as RFC 3339 `YYYY-MM-DDTHH:MM:SSZ`, optional fields omitted
    /// when nil.
    public func canonicalJSON() throws -> Data {
        var object: [String: Any] = [
            Field.id: id.uuidString.lowercased(),
            Field.email: email,
            Field.tier: tier.rawValue,
            Field.seats: seats,
            Field.issuedAt: RFC3339.string(from: issuedAt),
        ]
        if let updatesUntil {
            object[Field.updatesUntil] = RFC3339.string(from: updatesUntil)
        }
        return try JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys, .withoutEscapingSlashes])
    }

    /// Parse a payload. Accepts any key order and ignores unknown keys so a
    /// future issuer can add fields without invalidating older apps; rejects
    /// unknown tiers, non-positive seat counts, and unparseable dates.
    public init(canonicalJSON data: Data) throws(LicenseError) {
        let raw: Any
        do {
            raw = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw .malformedPayload("payload is not JSON")
        }
        guard let object = raw as? [String: Any] else {
            throw .malformedPayload("payload is not a JSON object")
        }
        guard let idString = object[Field.id] as? String, let id = UUID(uuidString: idString) else {
            throw .malformedPayload("missing or invalid 'id'")
        }
        guard let email = object[Field.email] as? String, !email.isEmpty else {
            throw .malformedPayload("missing 'email'")
        }
        guard let tierString = object[Field.tier] as? String else {
            throw .malformedPayload("missing 'tier'")
        }
        guard let tier = LicenseTier(rawValue: tierString) else {
            throw .malformedPayload("unknown tier '\(tierString)'")
        }
        let seats: Int
        if let value = object[Field.seats] {
            guard let number = value as? Int, number > 0 else {
                throw .malformedPayload("'seats' must be a positive integer")
            }
            seats = number
        } else {
            seats = 1
        }
        guard let issuedString = object[Field.issuedAt] as? String,
            let issuedAt = RFC3339.date(from: issuedString)
        else {
            throw .malformedPayload("missing or invalid 'issuedAt'")
        }
        var updatesUntil: Date?
        if let value = object[Field.updatesUntil] {
            guard let string = value as? String, let date = RFC3339.date(from: string) else {
                throw .malformedPayload("invalid 'updatesUntil'")
            }
            updatesUntil = date
        }
        self.init(
            id: id, email: email, tier: tier, seats: seats,
            issuedAt: issuedAt, updatesUntil: updatesUntil)
    }
}

/// RFC 3339 timestamps in UTC with whole-second precision — the only date
/// form that appears in a payload. Formatting truncates sub-second parts so
/// a round trip through JSON compares equal.
public enum RFC3339 {
    // `Date.ISO8601FormatStyle` (not `ISO8601DateFormatter`) because it is a
    // Sendable value type; its default is exactly `YYYY-MM-DDTHH:MM:SSZ`.
    private static let style = Date.ISO8601FormatStyle(timeZone: TimeZone(identifier: "UTC")!)

    public static func string(from date: Date) -> String {
        Date(timeIntervalSince1970: date.timeIntervalSince1970.rounded(.down)).formatted(style)
    }

    public static func date(from string: String) -> Date? {
        try? Date(string, strategy: style)
    }
}
