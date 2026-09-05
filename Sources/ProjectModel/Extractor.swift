import Foundation

/// The raw extraction guarantee (`docs/PROJECT_FORMAT.md` §9): copy committed
/// raw media plus a CSV/JSON event export to a destination, working even when
/// the manifest — or the whole journal — cannot be loaded.
public struct ExtractionReport: Codable, Sendable {
    public var projectPath: String
    public var destinationPath: String
    public var extractedAt: String
    public var mediaFiles: [String]
    public var eventExports: [String]
    public var cursorDescriptors: Int
    public var issues: [ValidationIssue]
}

public enum Extractor {

    public static func extract(
        projectAt projectURL: URL,
        to destination: URL,
        useHardLinks: Bool = false
    ) async throws -> ExtractionReport {
        let layout = ProjectLayout(root: projectURL)
        let fm = FileManager.default
        guard fm.fileExists(atPath: projectURL.path) else {
            throw ScreenreelError.notAProject(path: projectURL.path, reason: "no such directory")
        }
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)

        var issues: [ValidationIssue] = []
        var mediaFiles: [String] = []
        var eventExports: [String] = []

        // Prefer journal-committed descriptors; fall back to a directory sweep
        // so extraction still works with destroyed metadata.
        var committedMedia: [String] = []
        var committedChunks: [String] = []
        if fm.fileExists(atPath: layout.journalURL.path),
            let scan = try? JournalReader.scan(url: layout.journalURL)
        {
            for record in scan.records {
                if record.type == .segmentCommitted,
                    let seg = try? record.payload.decoded(as: SegmentDescriptor.self)
                {
                    committedMedia.append(seg.path)
                }
                if record.type == .eventChunkCommitted,
                    let chunk = try? record.payload.decoded(as: EventChunkDescriptor.self)
                {
                    committedChunks.append(chunk.path)
                }
            }
            if let reason = scan.truncationReason {
                issues.append(ValidationIssue(
                    .warning, code: "journal.torn",
                    message: "journal truncated (\(reason)); extracting the trusted prefix plus finalized files on disk"))
            }
        } else {
            issues.append(ValidationIssue(
                .warning, code: "journal.unreadable",
                message: "journal unreadable; extracting every finalized file found on disk"))
        }

        // Directory sweep to include finalized orphans (and everything, when
        // metadata is gone). Partial tails are copied under quarantine/.
        var mediaOnDisk: [String] = []
        var partials: [String] = []
        for dir in [
            layout.screenDirectory, layout.microphoneDirectory,
            layout.systemAudioDirectory, layout.cameraDirectory,
        ] {
            guard let entries = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            else { continue }
            for entry in entries.sorted(by: { $0.path < $1.path }) {
                let rel = layout.relativePath(of: entry)
                if entry.lastPathComponent.hasSuffix(ProjectLayout.partialSuffix) {
                    partials.append(rel)
                } else {
                    mediaOnDisk.append(rel)
                }
            }
        }
        let toExtract = Set(committedMedia).union(mediaOnDisk)

        for rel in toExtract.sorted() {
            guard let src = try? layout.resolve(relativePath: rel),
                fm.fileExists(atPath: src.path)
            else {
                issues.append(ValidationIssue(
                    .error, code: "asset.missing", message: "committed asset missing", path: rel))
                continue
            }
            let dst = destination.appendingPathComponent(rel)
            do {
                try copyOrLink(from: src, to: dst, useHardLinks: useHardLinks)
                mediaFiles.append(rel)
                if !committedMedia.contains(rel) && !committedMedia.isEmpty {
                    issues.append(ValidationIssue(
                        .info, code: "asset.orphanIncluded",
                        message: "file had no journal record but was finalized on disk; included", path: rel))
                }
            } catch {
                issues.append(ValidationIssue(
                    .error, code: "asset.copyFailed", message: "\(error)", path: rel))
            }
        }
        for rel in partials {
            guard let src = try? layout.resolve(relativePath: rel) else { continue }
            let dst = destination.appendingPathComponent("quarantine").appendingPathComponent(rel)
            try? copyOrLink(from: src, to: dst, useHardLinks: useHardLinks)
            issues.append(ValidationIssue(
                .info, code: "asset.partialTail",
                message: "interrupted write copied under quarantine/", path: rel))
        }

        // Cursor descriptor snapshots.
        var cursorCount = 0
        if let entries = try? fm.contentsOfDirectory(at: layout.cursorsDirectory, includingPropertiesForKeys: nil) {
            for entry in entries.sorted(by: { $0.path < $1.path }) {
                let rel = layout.relativePath(of: entry)
                try? copyOrLink(from: entry, to: destination.appendingPathComponent(rel), useHardLinks: useHardLinks)
                if entry.pathExtension == "json" { cursorCount += 1 }
            }
        }

        // Event export: merge every readable chunk, journal-committed or not.
        // A committed chunk that has vanished from disk is an error, exactly
        // as it is for media.
        var chunkFiles: [URL] = []
        if let entries = try? fm.contentsOfDirectory(at: layout.eventsDirectory, includingPropertiesForKeys: nil) {
            chunkFiles = entries
                .filter { $0.pathExtension == "jsonl" }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
        }
        for rel in Set(committedChunks) {
            guard let url = try? layout.resolve(relativePath: rel) else { continue }
            if !fm.fileExists(atPath: url.path) {
                issues.append(ValidationIssue(
                    .error, code: "asset.missing",
                    message: "committed event chunk missing from disk", path: rel))
            }
        }
        var records: [EventRecord] = []
        for chunk in chunkFiles {
            guard let data = try? Data(contentsOf: chunk),
                let text = String(data: data, encoding: .utf8)
            else { continue }
            var lineNumber = 0
            for line in text.split(separator: "\n") {
                lineNumber += 1
                if let record = try? EventRecord.parse(line: line, lineNumber: lineNumber) {
                    records.append(record)
                }
            }
        }
        records.sort { ($0.timeNs, $0.sequence) < ($1.timeNs, $1.sequence) }
        if !records.isEmpty {
            let jsonURL = destination.appendingPathComponent("events.json")
            try AtomicFile.writeJSON(records, to: jsonURL)
            eventExports.append("events.json")
            let csvURL = destination.appendingPathComponent("events.csv")
            try AtomicFile.write(Data(csv(for: records).utf8), to: csvURL)
            eventExports.append("events.csv")
        }

        let report = ExtractionReport(
            projectPath: projectURL.path,
            destinationPath: destination.path,
            extractedAt: RFC3339.now(),
            mediaFiles: mediaFiles,
            eventExports: eventExports,
            cursorDescriptors: cursorCount,
            issues: issues)
        try AtomicFile.writeJSON(
            report, to: destination.appendingPathComponent("extraction-report.json"))
        return report
    }

    private static func copyOrLink(from source: URL, to destination: URL, useHardLinks: Bool) throws {
        let fm = FileManager.default
        try fm.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: destination.path) { return }
        if useHardLinks {
            try fm.linkItem(at: source, to: destination)
        } else {
            try FileCloner.clone(from: source, to: destination)
        }
    }

    private static func csv(for records: [EventRecord]) -> String {
        var out = "sequence,timeNs,type,displayID,xPx,yPx,cursorID,buttons,button,clickCount,modifiers,deltaX,deltaY,keyCode\n"
        for r in records {
            let modifiers = (r.modifiers ?? []).map(\.rawValue).joined(separator: "|")
            let fields: [String] = [
                String(r.sequence), String(r.timeNs), r.type.rawValue,
                r.displayID.map(String.init) ?? "",
                r.xPx.map { String($0) } ?? "",
                r.yPx.map { String($0) } ?? "",
                r.cursorID ?? "",
                r.buttons.map(String.init) ?? "",
                r.button?.rawValue ?? "",
                r.clickCount.map(String.init) ?? "",
                modifiers,
                r.deltaX.map { String($0) } ?? "",
                r.deltaY.map { String($0) } ?? "",
                r.keyCode.map(String.init) ?? "",
            ]
            out += fields.joined(separator: ",") + "\n"
        }
        return out
    }
}
