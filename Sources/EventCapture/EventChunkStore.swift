import Foundation
import ProjectModel

/// Buffers input events and commits them as chunked JSONL files using the
/// same atomic `.partial` → fsync → rename → journal protocol as media
/// segments (`docs/PROJECT_FORMAT.md` §4, §6, ADR 0003). Owns the global
/// event sequence counter; records of different kinds share one ordering.
public actor EventChunkStore {
    public typealias CommitHandler = @Sendable (EventChunkDescriptor) async throws -> Void

    private struct PendingChunk {
        var records: [EventRecord] = []
        var startNs: Int64 = 0
    }

    private let layout: ProjectLayout
    private let trackIDs: [EventChunkKind: UUID]
    private let onCommit: CommitHandler
    private let maxRecordsPerChunk: Int
    private let maxChunkSpanNs: Int64

    private var nextSequence: UInt64 = 1
    private var chunkIndexes: [EventChunkKind: Int] = [:]
    private var pending: [EventChunkKind: PendingChunk] = [:]

    public init(
        layout: ProjectLayout,
        trackIDs: [EventChunkKind: UUID],
        maxRecordsPerChunk: Int = 1000,
        maxChunkSpanNs: Int64 = 5_000_000_000,
        onCommit: @escaping CommitHandler
    ) {
        self.layout = layout
        self.trackIDs = trackIDs
        self.maxRecordsPerChunk = maxRecordsPerChunk
        self.maxChunkSpanNs = maxChunkSpanNs
        self.onCommit = onCommit
    }

    /// Append one event. The store assigns the global sequence; any sequence
    /// on the incoming record is ignored.
    public func append(_ record: EventRecord) async throws {
        var record = record
        record.sequence = nextSequence
        nextSequence += 1

        let kind = record.chunkKind
        guard trackIDs[kind] != nil else { return }  // kind not captured this session
        var chunk = pending[kind] ?? PendingChunk()
        if chunk.records.isEmpty {
            chunk.startNs = record.timeNs
        }
        chunk.records.append(record)
        pending[kind] = chunk

        if chunk.records.count >= maxRecordsPerChunk
            || record.timeNs - chunk.startNs >= maxChunkSpanNs
        {
            try await commitPending(kind: kind)
        }
    }

    /// Commit every pending chunk (session stop).
    public func finish() async throws {
        for kind in pending.keys.sorted(by: { $0.rawValue < $1.rawValue }) {
            try await commitPending(kind: kind)
        }
    }

    private func commitPending(kind: EventChunkKind) async throws {
        guard var chunk = pending[kind], !chunk.records.isEmpty,
            let trackID = trackIDs[kind]
        else { return }
        // Take the batch out (records appended while we await below start a
        // new pending chunk), but on ANY failure put it back in front of the
        // newer records so nothing is ever silently lost; the caller surfaces
        // the error and the next append/finish retries the same chunk index.
        pending[kind] = nil
        let index = (chunkIndexes[kind] ?? 0) + 1
        do {
            try await writeAndCommit(chunk: &chunk, kind: kind, trackID: trackID, index: index)
            chunkIndexes[kind] = index
        } catch {
            var restored = chunk
            if let newer = pending[kind] {
                restored.records += newer.records
            }
            pending[kind] = restored
            throw error
        }
    }

    private func writeAndCommit(
        chunk: inout PendingChunk, kind: EventChunkKind, trackID: UUID, index: Int
    ) async throws {
        let fileName = ProjectLayout.chunkFileName(kind: kind, sequence: index, compression: .none)
        let finalURL = layout.eventsDirectory.appendingPathComponent(fileName)
        let partialURL = layout.eventsDirectory
            .appendingPathComponent(fileName + ProjectLayout.partialSuffix)

        chunk.records.sort { $0.sequence < $1.sequence }
        var lines = String()
        for record in chunk.records {
            lines += try record.jsonlLine() + "\n"
        }
        let data = Data(lines.utf8)

        // Atomic commit protocol: partial → fsync → rename → dir fsync.
        guard FileManager.default.createFile(atPath: partialURL.path, contents: nil) else {
            throw ScreenreelError.ioFailed(operation: "create chunk", path: partialURL.path, errno: errno)
        }
        let handle = try FileHandle(forWritingTo: partialURL)
        try handle.write(contentsOf: data)
        try AtomicFile.sync(fileDescriptor: handle.fileDescriptor, path: partialURL.path)
        try handle.close()
        try AtomicFile.rename(from: partialURL, to: finalURL)
        try AtomicFile.syncDirectory(layout.eventsDirectory)

        let descriptor = EventChunkDescriptor(
            trackID: trackID,
            kind: kind,
            path: layout.relativePath(of: finalURL),
            sequenceInTrack: index,
            compression: .none,
            firstEventSequence: chunk.records.first!.sequence,
            lastEventSequence: chunk.records.last!.sequence,
            startNs: chunk.records.first!.timeNs,
            endNs: chunk.records.last!.timeNs,
            recordCount: chunk.records.count,
            byteSize: Int64(data.count),
            sha256: Hashing.sha256Hex(data),
            commitSequence: 0)  // assigned by the session when journaled
        try await onCommit(descriptor)
    }
}
