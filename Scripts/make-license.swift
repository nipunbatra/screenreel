#!/usr/bin/env swift
// License key tooling for Screenreel. Run with `swift Scripts/make-license.swift …`.
//
// This script deliberately does not import the Licensing package (a `swift`
// script cannot), so the wire format is duplicated here and pinned by a
// fixture test in Tests/LicensingTests/ScriptCompatibilityTests.swift:
//
//   key     = "SR1-" + base64url(payload) + "-" + base64url(signature)
//   payload = canonical JSON: sorted keys, no whitespace, RFC 3339 UTC dates
//             {"email","id","issuedAt","seats","tier"[,"updatesUntil"]}
//   signature = Ed25519 over the exact payload bytes
//
// Commands:
//   --generate-keys <dir>
//       Writes <dir>/screenreel-license.private (mode 0600) and
//       <dir>/screenreel-license.public, and prints the public key base64 to
//       paste into Sources/Licensing/LicenseVerifier.swift
//       (LicensePublicKeys.productionBase64). NEVER commit the private file.
//   --issue --key <private-key-file> --email <addr> --tier personal|team
//           [--seats N] [--updates-until YYYY-MM-DD] [--id UUID]
//       Prints a license key. --updates-until is inclusive: the payload
//       stores 23:59:59Z on that day.
//   --inspect <key>
//       Prints the payload of a key WITHOUT verifying it.
//   --verify --public <base64|public-key-file> <key>
//       Verifies a key against a public key and prints the payload.

import CryptoKit
import Foundation

// MARK: - Helpers

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func base64url(_ data: Data) -> String {
    data.base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}

func base64urlDecode(_ string: String) -> Data? {
    var standard = string
        .replacingOccurrences(of: "-", with: "+")
        .replacingOccurrences(of: "_", with: "/")
    let remainder = standard.count % 4
    if remainder == 1 { return nil }
    if remainder > 0 { standard += String(repeating: "=", count: 4 - remainder) }
    return Data(base64Encoded: standard)
}

let utc = TimeZone(identifier: "UTC")!
let rfc3339 = Date.ISO8601FormatStyle(timeZone: utc)

func rfc3339String(_ date: Date) -> String {
    Date(timeIntervalSince1970: date.timeIntervalSince1970.rounded(.down)).formatted(rfc3339)
}

func endOfDay(_ yyyymmdd: String) -> Date {
    let parts = yyyymmdd.split(separator: "-").compactMap { Int($0) }
    guard parts.count == 3 else { fail("--updates-until must be YYYY-MM-DD, got '\(yyyymmdd)'") }
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = utc
    let components = DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: 23, minute: 59, second: 59)
    guard let date = calendar.date(from: components) else { fail("invalid date '\(yyyymmdd)'") }
    return date
}

func readPrivateKey(at path: String) -> Curve25519.Signing.PrivateKey {
    guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { fail("cannot read private key at \(path)") }
    guard let raw = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines)),
        let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw)
    else { fail("\(path) is not a base64 32-byte Ed25519 private key") }
    return key
}

func readPublicKey(_ value: String) -> Curve25519.Signing.PublicKey {
    var text = value
    if FileManager.default.fileExists(atPath: value), let contents = try? String(contentsOfFile: value, encoding: .utf8) {
        text = contents
    }
    guard let raw = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines)),
        let key = try? Curve25519.Signing.PublicKey(rawRepresentation: raw)
    else { fail("'\(value)' is not a base64 32-byte Ed25519 public key or a file containing one") }
    return key
}

func splitKey(_ raw: String) -> (payload: Data, signature: Data) {
    let key = String(raw.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) })
    guard key.hasPrefix("SR1-") else { fail("not an SR1 key") }
    let body = key.dropFirst(4)
    guard body.count >= 86 + 1 + 2 else { fail("key is truncated") }
    let separator = body.index(body.endIndex, offsetBy: -87)
    guard body[separator] == "-" else { fail("key is missing its separator") }
    guard let payload = base64urlDecode(String(body[body.startIndex..<separator])) else { fail("payload is not base64url") }
    guard let signature = base64urlDecode(String(body.suffix(86))), signature.count == 64 else { fail("signature is not a 64-byte base64url value") }
    return (payload, signature)
}

func canonicalPayload(_ object: [String: Any]) -> Data {
    guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]) else {
        fail("could not encode payload")
    }
    return data
}

// MARK: - Argument parsing

var arguments = Array(CommandLine.arguments.dropFirst())
guard let command = arguments.first else {
    fail("""
        usage:
          swift Scripts/make-license.swift --generate-keys <dir>
          swift Scripts/make-license.swift --issue --key <private-key-file> --email <addr> --tier personal|team [--seats N] [--updates-until YYYY-MM-DD] [--id UUID]
          swift Scripts/make-license.swift --inspect <key>
          swift Scripts/make-license.swift --verify --public <base64|file> <key>
        """)
}
arguments.removeFirst()

func option(_ name: String) -> String? {
    guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
    let value = arguments[index + 1]
    arguments.removeSubrange(index...(index + 1))
    return value
}

switch command {
case "--generate-keys":
    guard let directory = arguments.first else { fail("--generate-keys needs a directory") }
    let privateKey = Curve25519.Signing.PrivateKey()
    let privatePath = (directory as NSString).appendingPathComponent("screenreel-license.private")
    let publicPath = (directory as NSString).appendingPathComponent("screenreel-license.public")
    if FileManager.default.fileExists(atPath: privatePath) {
        fail("\(privatePath) already exists — refusing to overwrite a signing key")
    }
    do {
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try privateKey.rawRepresentation.base64EncodedString().write(toFile: privatePath, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: privatePath)
        try privateKey.publicKey.rawRepresentation.base64EncodedString().write(toFile: publicPath, atomically: true, encoding: .utf8)
    } catch {
        fail("could not write keys: \(error)")
    }
    print("Private key (keep out of Git, back it up):", privatePath)
    print("Public key file:", publicPath)
    print("")
    print("Paste this into Sources/Licensing/LicenseVerifier.swift as LicensePublicKeys.productionBase64:")
    print(privateKey.publicKey.rawRepresentation.base64EncodedString())

case "--issue":
    guard let keyPath = option("--key") else { fail("--issue needs --key <private-key-file>") }
    guard let email = option("--email"), email.contains("@") else { fail("--issue needs --email <address>") }
    guard let tier = option("--tier"), ["personal", "team"].contains(tier) else { fail("--tier must be personal or team") }
    let seatsText = option("--seats") ?? "1"
    guard let seats = Int(seatsText), seats > 0 else { fail("--seats must be a positive integer") }
    let updatesUntil = option("--updates-until").map(endOfDay)
    let idText = option("--id") ?? UUID().uuidString
    guard let id = UUID(uuidString: idText) else { fail("--id must be a UUID") }
    let issuedAt = option("--issued-at").map { text -> Date in
        guard let date = try? Date(text, strategy: rfc3339) else { fail("--issued-at must be RFC 3339 like 2026-09-05T10:00:00Z") }
        return date
    } ?? Date()
    guard arguments.isEmpty else { fail("unexpected arguments: \(arguments)") }

    var payload: [String: Any] = [
        "id": id.uuidString.lowercased(),
        "email": email,
        "tier": tier,
        "seats": seats,
        "issuedAt": rfc3339String(issuedAt),
    ]
    if let updatesUntil { payload["updatesUntil"] = rfc3339String(updatesUntil) }
    let bytes = canonicalPayload(payload)
    let privateKey = readPrivateKey(at: keyPath)
    guard let signature = try? privateKey.signature(for: bytes) else { fail("signing failed") }
    print("SR1-" + base64url(bytes) + "-" + base64url(signature))

case "--inspect":
    guard let key = arguments.first else { fail("--inspect needs a key") }
    let (payload, _) = splitKey(key)
    print(String(decoding: payload, as: UTF8.self))
    print("(not verified)")

case "--verify":
    guard let publicValue = option("--public") else { fail("--verify needs --public <base64|file>") }
    guard let key = arguments.first else { fail("--verify needs a key") }
    let publicKey = readPublicKey(publicValue)
    let (payload, signature) = splitKey(key)
    guard publicKey.isValidSignature(signature, for: payload) else { fail("INVALID: signature does not match this public key") }
    print("VALID")
    print(String(decoding: payload, as: UTF8.self))

default:
    fail("unknown command \(command)")
}
