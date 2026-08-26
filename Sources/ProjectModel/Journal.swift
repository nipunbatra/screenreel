import Foundation

/// Result of scanning a journal file. `records` is the trusted prefix:
/// everything up to (excluding) the first torn line, checksum failure, chain
/// break, or sequence gap. Recovery never reads past `records`.
public struct JournalScan: Sendable {
    public var records: [JournalRecord]
    /// Nil when the whole file verified; otherwise why scanning stopped.
    public var truncationReason: String?
    /// 1-based line number scanning stopped at (first untrusted line).
    public var truncatedAtLine: Int?

    public var lastSequence: UInt64 { records.last?.sequence ?? 0 }
    public var lastHash: String { records.last?.hash ?? journalGenesisHash }

    public func records(ofType type: JournalRecordType) -> [JournalRecord] {
        records.filter { $0.type == type }
    }

    public var isFinalized: Bool {
        records.last?.type == .sessionFinalized
    }
}

public enum JournalReader {
    /// Scan and verify a journal. Tolerant by design: a broken tail yields a
    /// shorter trusted prefix, not an error. Only a missing file throws.
    public static func scan(url: URL) throws -> JournalScan {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw AksError.ioFailed(operation: "read journal", path: url.path, errno: ENOENT)
        }
        guard let text = String(data: data, encoding: .utf8) else {
            return JournalScan(records: [], truncationReason: "journal is not valid UTF-8", truncatedAtLine: 1)
        }

        var records: [JournalRecord] = []
        var expectedSequence: UInt64 = 1
        var expectedPrevHash = journalGenesisHash

        // Preserve a trailing torn line: split keeps empty subsequences off,
        // so track line numbers manually.
        var lineNumber = 0
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            lineNumber += 1
            if line.isEmpty { continue }  // allow trailing newline
            let record: JournalRecord
            do {
                record = try JSONDecoder().decode(JournalRecord.self, from: Data(line.utf8))
            } catch {
                return JournalScan(
                    records: records,
                    truncationReason: "unparseable (torn?) record: \(error)",
                    truncatedAtLine: lineNumber)
            }
            guard record.schemaVersion <= AksSchema.currentVersion else {
                return JournalScan(
                    records: records,
                    truncationReason: "record schemaVersion \(record.schemaVersion) is newer than supported \(AksSchema.currentVersion)",
                    truncatedAtLine: lineNumber)
            }
            guard record.sequence == expectedSequence else {
                return JournalScan(
                    records: records,
                    truncationReason: "sequence gap: expected \(expectedSequence), found \(record.sequence)",
                    truncatedAtLine: lineNumber)
            }
            guard record.prevHash == expectedPrevHash else {
                return JournalScan(
                    records: records,
                    truncationReason: "hash chain break at sequence \(record.sequence)",
                    truncatedAtLine: lineNumber)
            }
            guard let computed = try? record.computedHash(), computed == record.hash else {
                return JournalScan(
                    records: records,
                    truncationReason: "checksum mismatch at sequence \(record.sequence)",
                    truncatedAtLine: lineNumber)
            }
            records.append(record)
            expectedSequence += 1
            expectedPrevHash = record.hash
        }
        return JournalScan(records: records, truncationReason: nil, truncatedAtLine: nil)
    }
}

/// Owner of the append side of a journal. All appends are serialized through
/// the actor; commit-critical records are durable (F_FULLFSYNC) before the
/// call returns, which is what makes `segmentCommitted` a real commit point.
public actor JournalWriter {
    private let file: DurableAppendFile
    private var nextSequence: UInt64
    private var prevHash: String

    /// Open for a brand-new project (empty journal).
    public init(creatingAt url: URL) throws {
        self.file = try DurableAppendFile(url: url)
        self.nextSequence = 1
        self.prevHash = journalGenesisHash
    }

    /// Open an existing journal and continue after its trusted prefix.
    /// Refuses to continue a journal with a broken tail — recovery must run
    /// first so the torn tail is preserved as evidence.
    public init(resumingAt url: URL) throws {
        let scan = try JournalReader.scan(url: url)
        if let reason = scan.truncationReason {
            throw AksError.journalInvalid(reason: reason, atLine: scan.truncatedAtLine ?? 0)
        }
        self.file = try DurableAppendFile(url: url)
        self.nextSequence = scan.lastSequence + 1
        self.prevHash = scan.lastHash
    }

    public var lastCommittedSequence: UInt64 { nextSequence - 1 }

    /// Append a record whose payload embeds the record's own sequence number
    /// (e.g. a descriptor's `commitSequence`). The builder runs inside this
    /// actor with the exact sequence the record will get, so payload and
    /// record can never disagree — the read-then-append idiom across two
    /// suspension points cannot make this atomic and must not be used.
    @discardableResult
    public func append(
        type: JournalRecordType,
        timeNs: Int64,
        durable: Bool = true,
        payloadForSequence: @Sendable (UInt64) throws -> JSONValue
    ) throws -> JournalRecord {
        let payload = try payloadForSequence(nextSequence)
        return try append(type: type, timeNs: timeNs, payload: payload, durable: durable)
    }

    /// Append a record. Returns the fully-populated record (with sequence and
    /// hashes) after it is durable to the requested level.
    @discardableResult
    public func append(
        type: JournalRecordType,
        timeNs: Int64,
        payload: JSONValue,
        durable: Bool = true
    ) throws -> JournalRecord {
        var record = JournalRecord(
            schemaVersion: AksSchema.currentVersion,
            sequence: nextSequence,
            type: type,
            timeNs: timeNs,
            wallTime: RFC3339.now(),
            payload: payload,
            prevHash: prevHash,
            hash: "")
        record.hash = try record.computedHash()
        let line = try record.jsonlLine() + "\n"
        try file.append(Data(line.utf8), durable: durable)
        nextSequence += 1
        prevHash = record.hash
        return record
    }

    public func synchronize() throws {
        try file.synchronize()
    }

    /// Append an existing, already-hashed record verbatim (recovery rebuilding
    /// a trusted prefix). Sequence, chain, and checksum are re-verified; the
    /// bytes are not made durable individually — callers finish with a durable
    /// record or `synchronize()`.
    public func replayVerified(_ record: JournalRecord) throws {
        guard record.sequence == nextSequence else {
            throw AksError.journalInvalid(
                reason: "replay sequence \(record.sequence), expected \(nextSequence)",
                atLine: Int(record.sequence))
        }
        guard record.prevHash == prevHash else {
            throw AksError.journalInvalid(
                reason: "replay chain break at sequence \(record.sequence)",
                atLine: Int(record.sequence))
        }
        guard let computed = try? record.computedHash(), computed == record.hash else {
            throw AksError.journalInvalid(
                reason: "replay checksum mismatch at sequence \(record.sequence)",
                atLine: Int(record.sequence))
        }
        let line = try record.jsonlLine() + "\n"
        try file.append(Data(line.utf8), durable: false)
        nextSequence += 1
        prevHash = record.hash
    }
}
