import Foundation

/// Version constants for the on-disk contract. Bump rules live in
/// `docs/PROJECT_FORMAT.md` §8; every released version keeps a fixture in
/// `Tests/ProjectModelTests/Fixtures`.
public enum ProjectSchema {
    /// Manifest, journal, event, cursor-descriptor, and session-lock schemas
    /// all share one project schema version in v0.1.
    public static let currentVersion = 1

    /// The `format` discriminator written into every new manifest.
    public static let formatIdentifier = "com.nipunbatra.screenreel.project"

    /// Discriminators older builds wrote (the product was called "Aks");
    /// they are read forever, never rewritten in place.
    public static let legacyFormatIdentifiers: Set<String> = ["in.aks.project"]

    public static func isKnownFormat(_ format: String) -> Bool {
        format == formatIdentifier || legacyFormatIdentifiers.contains(format)
    }

    /// Written into descriptors and journal payloads as `toolVersion`.
    public static let toolVersion = "screenreel 0.2.1"

    /// Package directory suffix for new recordings.
    public static let packageExtension = "screenreel"

    /// Suffixes older builds used; packages with them still open everywhere.
    public static let legacyPackageExtensions: Set<String> = ["aks"]

    public static func isPackageExtension(_ ext: String) -> Bool {
        ext == packageExtension || legacyPackageExtensions.contains(ext)
    }
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
