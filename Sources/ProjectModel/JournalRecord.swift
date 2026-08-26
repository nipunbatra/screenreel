import Foundation

// The write-ahead session journal (`docs/PROJECT_FORMAT.md` §5): an
// append-only JSONL file where each record carries a monotonic sequence,
// the previous record's hash, and its own SHA-256 over the canonical
// serialization with `hash` removed. Recovery trusts committed media plus
// journal ordering, never the last manifest alone.

public enum JournalRecordType: String, Codable, Sendable, CaseIterable {
    case sessionCreated
    case trackStarted
    case segmentOpened
    case segmentCommitted
    case eventChunkCommitted
    case deviceChanged
    case discontinuity
    case fault
    case pause
    case resume
    case editSnapshotCommitted
    case sessionStopped
    case validationCompleted
    case sessionFinalized
}

public struct JournalRecord: Codable, Sendable, Equatable {
    public var schemaVersion: Int
    public var sequence: UInt64
    public var type: JournalRecordType
    public var timeNs: Int64
    public var wallTime: String
    public var payload: JSONValue
    public var prevHash: String
    public var hash: String

    /// Compute the canonical hash of this record with `hash` excluded.
    public func computedHash() throws -> String {
        let fields: [String: JSONValue] = [
            "schemaVersion": .integer(Int64(schemaVersion)),
            "sequence": .integer(Int64(bitPattern: sequence)),
            "type": .string(type.rawValue),
            "timeNs": .integer(timeNs),
            "wallTime": .string(wallTime),
            "payload": payload,
            "prevHash": .string(prevHash),
            // `hash` intentionally absent.
        ]
        return Hashing.sha256Hex(try JSONValue.object(fields).canonicalData())
    }

    /// Serialized single-line form written to journal.jsonl.
    public func jsonlLine() throws -> String {
        let fields: [String: JSONValue] = [
            "schemaVersion": .integer(Int64(schemaVersion)),
            "sequence": .integer(Int64(bitPattern: sequence)),
            "type": .string(type.rawValue),
            "timeNs": .integer(timeNs),
            "wallTime": .string(wallTime),
            "payload": payload,
            "prevHash": .string(prevHash),
            "hash": .string(hash),
        ]
        return try JSONValue.object(fields).canonicalString()
    }
}

/// Typed payload helpers so call sites do not hand-build JSON.
public enum JournalPayload {
    public static func sessionCreated(manifest: Manifest) throws -> JSONValue {
        try JSONValue(encoding: [
            "projectID": manifest.projectID.uuidString,
            "appVersion": manifest.appVersion,
        ])
    }

    public static func trackStarted(_ track: TrackDescriptor) throws -> JSONValue {
        try JSONValue(encoding: track)
    }

    public static func segmentOpened(trackID: UUID, path: String, sequenceInTrack: Int) throws -> JSONValue {
        try JSONValue(encoding: [
            "trackID": .string(trackID.uuidString),
            "path": .string(path),
            "sequenceInTrack": .integer(Int64(sequenceInTrack)),
        ] as [String: JSONValue])
    }

    public static func segmentCommitted(_ segment: SegmentDescriptor) throws -> JSONValue {
        try JSONValue(encoding: segment)
    }

    public static func eventChunkCommitted(_ chunk: EventChunkDescriptor) throws -> JSONValue {
        try JSONValue(encoding: chunk)
    }

    public static func fault(kind: String, message: String) throws -> JSONValue {
        try JSONValue(encoding: ["kind": kind, "message": message])
    }

    public static func deviceChanged(trackID: UUID, deviceUID: String?, detail: String) throws -> JSONValue {
        try JSONValue(encoding: [
            "trackID": .string(trackID.uuidString),
            "deviceUID": deviceUID.map { JSONValue.string($0) } ?? .null,
            "detail": .string(detail),
        ] as [String: JSONValue])
    }

    public static func discontinuity(trackID: UUID?, startNs: Int64, endNs: Int64?, reason: String) throws -> JSONValue {
        try JSONValue(encoding: [
            "trackID": trackID.map { JSONValue.string($0.uuidString) } ?? .null,
            "startNs": .integer(startNs),
            "endNs": endNs.map { JSONValue.integer($0) } ?? .null,
            "reason": .string(reason),
        ] as [String: JSONValue])
    }

    public static func empty() -> JSONValue { .object([:]) }
}
