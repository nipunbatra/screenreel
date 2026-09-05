import Foundation

/// A JSON document as a value type, with a canonical serialization used for
/// journal hashing: object keys sorted, no whitespace, integers without
/// exponent, doubles in Swift's shortest round-trip form.
public indirect enum JSONValue: Sendable, Equatable, Codable {
    case null
    case bool(Bool)
    case integer(Int64)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let b = try? container.decode(Bool.self) {
            self = .bool(b)
        } else if let i = try? container.decode(Int64.self) {
            self = .integer(i)
        } else if let d = try? container.decode(Double.self) {
            self = .double(d)
        } else if let s = try? container.decode(String.self) {
            self = .string(s)
        } else if let a = try? container.decode([JSONValue].self) {
            self = .array(a)
        } else if let o = try? container.decode([String: JSONValue].self) {
            self = .object(o)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "Unsupported JSON value")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let b): try container.encode(b)
        case .integer(let i): try container.encode(i)
        case .double(let d): try container.encode(d)
        case .string(let s): try container.encode(s)
        case .array(let a): try container.encode(a)
        case .object(let o): try container.encode(o)
        }
    }
}

extension JSONValue {
    public subscript(key: String) -> JSONValue? {
        if case .object(let o) = self { return o[key] }
        return nil
    }

    public var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    public var integerValue: Int64? {
        if case .integer(let i) = self { return i }
        return nil
    }

    /// Numeric value whether the JSON carried it as integer or double
    /// (whole doubles round-trip through canonical JSON as integers).
    public var doubleValue: Double? {
        switch self {
        case .double(let d): return d
        case .integer(let i): return Double(i)
        default: return nil
        }
    }

    /// Re-encode this value into a concrete `Decodable` type.
    public func decoded<T: Decodable>(as type: T.Type) throws -> T {
        let data = try canonicalData()
        return try JSONDecoder().decode(T.self, from: data)
    }

    /// Build a `JSONValue` from any `Encodable` value.
    public init<T: Encodable>(encoding value: T) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(value)
        self = try JSONDecoder().decode(JSONValue.self, from: data)
    }

    /// Parse a JSON document.
    public init(data: Data) throws {
        self = try JSONDecoder().decode(JSONValue.self, from: data)
    }
}

// MARK: - Canonical serialization

extension JSONValue {
    /// Deterministic serialization: sorted object keys, no whitespace, `\u{XXXX}`
    /// escapes only where JSON requires them. This byte sequence is what journal
    /// hashes are computed over.
    public func canonicalData() throws -> Data {
        var out = String()
        try serialize(into: &out)
        return Data(out.utf8)
    }

    public func canonicalString() throws -> String {
        var out = String()
        try serialize(into: &out)
        return out
    }

    private func serialize(into out: inout String) throws {
        switch self {
        case .null:
            out += "null"
        case .bool(let b):
            out += b ? "true" : "false"
        case .integer(let i):
            out += String(i)
        case .double(let d):
            guard d.isFinite else {
                throw ScreenreelError.invalidJSON("Non-finite number cannot be serialized to JSON")
            }
            // Whole doubles up to 2^53 print as integer digits: the
            // exponent form ("2e+15") reparsed as Int64 and re-serialized
            // to DIFFERENT bytes, breaking canonical-hash idempotency.
            if d == d.rounded(), abs(d) <= 9_007_199_254_740_992 {
                out += String(Int64(d))
            } else {
                out += "\(d)"  // Swift shortest round-trip representation
            }
        case .string(let s):
            Self.serializeString(s, into: &out)
        case .array(let items):
            out += "["
            for (index, item) in items.enumerated() {
                if index > 0 { out += "," }
                try item.serialize(into: &out)
            }
            out += "]"
        case .object(let fields):
            out += "{"
            for (index, key) in fields.keys.sorted().enumerated() {
                if index > 0 { out += "," }
                Self.serializeString(key, into: &out)
                out += ":"
                try fields[key]!.serialize(into: &out)
            }
            out += "}"
        }
    }

    private static func serializeString(_ s: String, into out: inout String) {
        out += "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        out += "\""
    }
}
