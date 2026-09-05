import Foundation

/// Version constants for the on-disk contract. Bump rules live in
/// `docs/PROJECT_FORMAT.md` §8; every released version keeps a fixture in
/// `Tests/ProjectModelTests/Fixtures`.
public enum AksSchema {
    /// Manifest, journal, event, cursor-descriptor, and session-lock schemas
    /// all share one project schema version in v0.1.
    public static let currentVersion = 1

    /// The `format` discriminator stored in every manifest.
    public static let formatIdentifier = "in.aks.project"

    /// Written into descriptors and journal payloads as `toolVersion`.
    public static let toolVersion = "aks 0.2.0"

    /// Package directory suffix.
    public static let packageExtension = "aks"
}

/// 64 hex zeros; `prevHash` of the first journal record.
public let journalGenesisHash = String(repeating: "0", count: 64)

public enum RFC3339 {
    private static let fractional = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    private static let plain = Date.ISO8601FormatStyle(includingFractionalSeconds: false)

    public static func now() -> String { string(from: Date()) }

    public static func string(from date: Date) -> String {
        date.formatted(fractional)
    }

    public static func date(from string: String) -> Date? {
        if let date = try? Date(string, strategy: fractional) { return date }
        // Accept timestamps without fractional seconds.
        return try? Date(string, strategy: plain)
    }
}
