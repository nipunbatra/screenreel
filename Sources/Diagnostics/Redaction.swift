import Foundation
import ProjectModel

/// Redaction for diagnostics output: reports must stay shareable without leaking the
/// account name inside home-directory paths or credentials inside URL query
/// strings (`docs/TECHNICAL_DESIGN.md` §10). Rules apply to every string
/// LEAF of a JSON document; structure and non-string values are untouched,
/// so the result is still valid, round-trippable JSON.
public enum Redaction {
    // Computed because `Regex` is not Sendable; literals are cheap to build
    // at diagnostics frequency.

    /// `/Users/<name>` (any user, anywhere in the string) → `~`. The rest of
    /// the path survives — it is the username that identifies a person.
    private static var homeDirectory: Regex<Substring> { /\/Users\/[^\/\s"',;)]+/ }
    /// Every query value in a URL-ish string → `…`. Keys survive so the
    /// shape of a request stays diagnosable; values (tokens, signatures,
    /// emails) do not.
    private static var queryValue: Regex<(Substring, Substring)> {
        /([?&][^=&?#\s"']+=)[^&#\s"']*/
    }

    public static func redact(_ string: String) -> String {
        var output = string.replacing(homeDirectory, with: "~")
        output = output.replacing(queryValue) { match in String(match.output.1) + "…" }
        return output
    }

    /// Redact every string leaf; arrays and objects recurse, everything else
    /// passes through unchanged.
    public static func redact(_ value: JSONValue) -> JSONValue {
        switch value {
        case .string(let string):
            return .string(redact(string))
        case .array(let items):
            return .array(items.map { redact($0) })
        case .object(let fields):
            return .object(fields.mapValues { redact($0) })
        default:
            return value
        }
    }

    /// Redact any Codable report by round-tripping it through JSON. Decoding
    /// the redacted document back into `T` is the proof that redaction kept
    /// the report structurally valid.
    public static func redact<T: Codable>(_ report: T) throws -> T {
        try redact(JSONValue(encoding: report)).decoded(as: T.self)
    }

    /// Redact a JSONL diagnostics log (e.g. `capture.jsonl`) line by line.
    /// A corrupt entry is skipped — never allowed to fail the whole report,
    /// and never emitted unredacted.
    public static func redactJSONLines(_ text: String) -> String {
        var lines: [String] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard
                let value = try? JSONValue(data: Data(line.utf8)),
                let redacted = try? redact(value).canonicalString()
            else { continue }
            lines.append(redacted)
        }
        return lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
    }
}
