import ArgumentParser
import Foundation
import ProjectModel

struct Inspect: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Print a project's manifest summary and journal contents.")

    @Argument(help: "Path to the .aks project package.")
    var project: String

    @Flag(help: "Dump every trusted journal record.")
    var journal = false

    @Flag(help: "Emit JSON (manifest, journal scan summary, session lock).")
    var json = false

    struct JSONReport: Codable {
        var manifest: Manifest
        var journalRecords: Int
        var journalTruncationReason: String?
        var journalFinalized: Bool
        var sessionLock: SessionLock?
    }

    func run() async throws {
        let loaded = try ProjectPackage.load(at: projectURL(from: project))
        if json {
            try Output.json(JSONReport(
                manifest: loaded.manifest,
                journalRecords: loaded.journal.records.count,
                journalTruncationReason: loaded.journal.truncationReason,
                journalFinalized: loaded.journal.isFinalized,
                sessionLock: loaded.sessionLock))
            return
        }

        let manifest = loaded.manifest
        print("Project ID: \(manifest.projectID.uuidString)")
        print("Schema:     v\(manifest.schemaVersion), \(manifest.appVersion), generation \(manifest.generation)")
        print("State:      \(manifest.state.rawValue)")
        print("Created:    \(manifest.createdAt)")
        print("Duration:   \(Output.duration(ns: manifest.durationNs ?? 0))")
        print("Clock:      origin continuous=\(manifest.clock.originContinuousTicks) absolute=\(manifest.clock.originAbsoluteTicks) timebase=\(manifest.clock.timebaseNumer)/\(manifest.clock.timebaseDenom) wall=\(manifest.clock.originWallTime)")
        for track in manifest.tracks {
            var line = "Track:      \(track.type.rawValue)"
            if let displayID = track.displayID { line += " display=\(displayID)" }
            if let device = track.deviceName { line += " device=\(device)" }
            if let segments = track.segments {
                let bytes = segments.reduce(Int64(0)) { $0 + $1.byteSize }
                line += " — \(segments.count) segments, \(Output.bytes(bytes))"
            }
            if let chunks = track.eventChunks {
                let records = chunks.reduce(0) { $0 + $1.recordCount }
                line += " — \(chunks.count) chunks, \(records) events"
            }
            print(line)
        }
        if let lock = loaded.sessionLock {
            print("Session:    INCOMPLETE marker present (pid \(lock.pid), heartbeat \(lock.heartbeatAt), writer alive: \(lock.writerIsAlive()))")
        }
        var journalLine = "Journal:    \(loaded.journal.records.count) trusted records"
        if let reason = loaded.journal.truncationReason {
            journalLine += " — TRUNCATED: \(reason)"
        } else if loaded.journal.isFinalized {
            journalLine += " — finalized"
        }
        print(journalLine)
        if journal {
            for record in loaded.journal.records {
                let payload = (try? record.payload.canonicalString()) ?? "{}"
                let clipped = payload.count > 120 ? String(payload.prefix(117)) + "..." : payload
                print(String(format: "  %5d %-22s t=%@ %@",
                    record.sequence,
                    (record.type.rawValue as NSString).utf8String ?? "",
                    Output.duration(ns: record.timeNs), clipped))
            }
        }
    }
}
