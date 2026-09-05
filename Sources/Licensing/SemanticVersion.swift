import Foundation

/// Minimal semantic version: `MAJOR.MINOR.PATCH[-prerelease]`, with a
/// tolerant parser for release tags (`v0.2.0`, `0.2`) and build metadata
/// (`+abc`, ignored for ordering per SemVer §10).
public struct SemanticVersion: Equatable, Hashable, Comparable, Sendable, CustomStringConvertible {
    public var major: Int
    public var minor: Int
    public var patch: Int
    /// Dot-separated prerelease identifiers; empty for a release.
    public var prerelease: [String]

    public init(_ major: Int, _ minor: Int, _ patch: Int, prerelease: [String] = []) {
        self.major = major
        self.minor = minor
        self.patch = patch
        self.prerelease = prerelease
    }

    /// Parse `"v1.2.3"`, `"1.2.3-beta.1"`, `"1.2"`, `"1"`. Returns nil for
    /// anything that is not a version (empty, letters in numeric parts, more
    /// than three numeric components).
    public init?(_ string: String) {
        var text = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("v") || text.hasPrefix("V") { text.removeFirst() }
        if let plus = text.firstIndex(of: "+") { text = String(text[..<plus]) }
        var prerelease: [String] = []
        if let dash = text.firstIndex(of: "-") {
            let tail = text[text.index(after: dash)...]
            guard !tail.isEmpty else { return nil }
            prerelease = tail.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
            guard prerelease.allSatisfy({ !$0.isEmpty }) else { return nil }
            text = String(text[..<dash])
        }
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count) else { return nil }
        var numbers: [Int] = []
        for part in parts {
            guard !part.isEmpty, part.allSatisfy(\.isNumber), let value = Int(part) else { return nil }
            numbers.append(value)
        }
        while numbers.count < 3 { numbers.append(0) }
        self.init(numbers[0], numbers[1], numbers[2], prerelease: prerelease)
    }

    public var description: String {
        let core = "\(major).\(minor).\(patch)"
        return prerelease.isEmpty ? core : core + "-" + prerelease.joined(separator: ".")
    }

    public static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        if lhs.patch != rhs.patch { return lhs.patch < rhs.patch }
        // A prerelease sorts before the release it precedes (SemVer §11.4).
        switch (lhs.prerelease.isEmpty, rhs.prerelease.isEmpty) {
        case (true, true): return false
        case (false, true): return true
        case (true, false): return false
        case (false, false): break
        }
        for (l, r) in zip(lhs.prerelease, rhs.prerelease) {
            if l == r { continue }
            switch (Int(l), Int(r)) {
            case let (li?, ri?): return li < ri
            case (.some, .none): return true  // numeric < alphanumeric
            case (.none, .some): return false
            case (.none, .none): return l < r
            }
        }
        return lhs.prerelease.count < rhs.prerelease.count
    }
}
