import Foundation

public struct ValidationIssue: Codable, Sendable, Equatable {
    public enum Severity: String, Codable, Sendable, Comparable {
        case info, warning, error

        public static func < (lhs: Severity, rhs: Severity) -> Bool {
            let order: [Severity] = [.info, .warning, .error]
            return order.firstIndex(of: lhs)! < order.firstIndex(of: rhs)!
        }
    }

    public var severity: Severity
    /// Stable machine-readable code, e.g. `segment.missing`, `journal.torn`.
    public var code: String
    public var message: String
    public var path: String?

    public init(_ severity: Severity, code: String, message: String, path: String? = nil) {
        self.severity = severity
        self.code = code
        self.message = message
        self.path = path
    }
}

public struct TrackValidationSummary: Codable, Sendable {
    public var trackID: UUID
    public var type: TrackType
    public var committedSegments: Int
    public var committedChunks: Int
    public var committedBytes: Int64
    public var coverageEndNs: Int64
}

public struct ValidationReport: Codable, Sendable {
    public var projectPath: String
    public var checkedAt: String
    public var toolVersion: String
    public var manifestGeneration: Int?
    public var state: ProjectState?
    public var journalRecordCount: Int
    public var journalLastSequence: UInt64
    public var journalTruncationReason: String?
    public var journalTruncatedAtLine: Int?
    public var journalFinalized: Bool
    public var incompleteSessionDetected: Bool
    public var tracks: [TrackValidationSummary]
    public var orphanCandidates: [String]
    public var partialTails: [String]
    public var issues: [ValidationIssue]

    public var isHealthy: Bool {
        !issues.contains { $0.severity == .error }
    }

    public var needsRecovery: Bool {
        incompleteSessionDetected || journalTruncationReason != nil || state == .recording
    }
}

/// Read-only project validation. Never mutates the package; always produces a
/// report (internal failures become `error` issues, not thrown errors).
public struct Validator: Sendable {
    public struct Options: Sendable {
        /// Verify SHA-256 of every committed asset (the default; `--fast` in
        /// the CLI disables it).
        public var verifyChecksums: Bool
        /// Probe every committed media container when an inspector is given.
        public var mediaInspector: MediaInspecting?
        /// Tolerance when comparing descriptor time ranges against container
        /// durations. One 30 fps frame + scheduling slack.
        public var durationToleranceNs: Int64

        public init(
            verifyChecksums: Bool = true,
            mediaInspector: MediaInspecting? = nil,
            durationToleranceNs: Int64 = 43_333_334
        ) {
            self.verifyChecksums = verifyChecksums
            self.mediaInspector = mediaInspector
            self.durationToleranceNs = durationToleranceNs
        }
    }

    public let options: Options

    public init(options: Options = Options()) {
        self.options = options
    }

    public func validate(projectAt url: URL) async -> ValidationReport {
        var issues: [ValidationIssue] = []
        var report = ValidationReport(
            projectPath: url.path,
            checkedAt: RFC3339.now(),
            toolVersion: ProjectSchema.toolVersion,
            manifestGeneration: nil,
            state: nil,
            journalRecordCount: 0,
            journalLastSequence: 0,
            journalTruncationReason: nil,
            journalTruncatedAtLine: nil,
            journalFinalized: false,
            incompleteSessionDetected: false,
            tracks: [],
            orphanCandidates: [],
            partialTails: [],
            issues: [])

        let loaded: ProjectPackage.Loaded
        do {
            loaded = try ProjectPackage.load(at: url)
        } catch {
            issues.append(ValidationIssue(
                .error, code: "project.unreadable", message: "\(error)", path: url.path))
            report.issues = issues
            return report
        }

        let layout = loaded.layout
        let manifest = loaded.manifest
        let journal = loaded.journal
        report.manifestGeneration = manifest.generation
        report.state = manifest.state
        report.journalRecordCount = journal.records.count
        report.journalLastSequence = journal.lastSequence
        report.journalTruncationReason = journal.truncationReason
        report.journalTruncatedAtLine = journal.truncatedAtLine
        report.journalFinalized = journal.isFinalized

        for problem in manifest.validatePaths() {
            issues.append(ValidationIssue(.error, code: "manifest.unsafePath", message: problem))
        }
        if manifest.clock.timebaseNumer == 0 || manifest.clock.timebaseDenom == 0 {
            issues.append(ValidationIssue(
                .error, code: "manifest.clockInvalid",
                message: "clock timebase must be positive"))
        }

        // Journal tail state.
        if let reason = journal.truncationReason {
            let severity: ValidationIssue.Severity = manifest.state == .ready ? .error : .warning
            issues.append(ValidationIssue(
                severity, code: "journal.torn",
                message: "journal trusted prefix ends at line \(journal.truncatedAtLine ?? 0): \(reason). "
                    + "Run `screenreel recover` to rebuild from committed data."))
        }

        // Incomplete session marker.
        if let lock = loaded.sessionLock {
            if lock.writerIsAlive() {
                issues.append(ValidationIssue(
                    .error, code: "session.active",
                    message: "a live session (pid \(lock.pid)) is writing this project; validate after it stops"))
            } else {
                report.incompleteSessionDetected = true
                issues.append(ValidationIssue(
                    .warning, code: "session.incomplete",
                    message: "session.lock present and writer is gone — the session did not close cleanly. "
                        + "Run `screenreel recover` to produce a recovered copy."))
            }
        } else if manifest.state == .recording {
            issues.append(ValidationIssue(
                .warning, code: "session.stateMismatch",
                message: "manifest state is 'recording' but session.lock is absent"))
        }

        // Committed descriptors from the trusted journal prefix are the source
        // of truth for what must exist on disk.
        var journalSegments: [String: SegmentDescriptor] = [:]
        var journalChunks: [String: EventChunkDescriptor] = [:]
        var openedSegmentPaths: [String] = []
        for record in journal.records {
            do {
                switch record.type {
                case .segmentOpened:
                    if let path = record.payload["path"]?.stringValue {
                        openedSegmentPaths.append(path)
                    }
                case .segmentCommitted:
                    let seg = try record.payload.decoded(as: SegmentDescriptor.self)
                    journalSegments[seg.path] = seg
                    if seg.commitSequence != record.sequence {
                        issues.append(ValidationIssue(
                            .warning, code: "journal.commitSequenceMismatch",
                            message: "descriptor commitSequence \(seg.commitSequence) but journaled at sequence \(record.sequence)",
                            path: seg.path))
                    }
                case .eventChunkCommitted:
                    let chunk = try record.payload.decoded(as: EventChunkDescriptor.self)
                    journalChunks[chunk.path] = chunk
                    if chunk.commitSequence != record.sequence {
                        issues.append(ValidationIssue(
                            .warning, code: "journal.commitSequenceMismatch",
                            message: "descriptor commitSequence \(chunk.commitSequence) but journaled at sequence \(record.sequence)",
                            path: chunk.path))
                    }
                default:
                    break
                }
            } catch {
                issues.append(ValidationIssue(
                    .error, code: "journal.payloadInvalid",
                    message: "sequence \(record.sequence) (\(record.type.rawValue)): \(error)"))
            }
        }

        // After a clean stop, every opened segment must have committed; a
        // finalize failure would otherwise hide lost media behind a healthy
        // report. (During recording/crash, an open tail is expected.)
        let sessionStopped = journal.records.contains { $0.type == .sessionStopped }
        if sessionStopped {
            for path in openedSegmentPaths where journalSegments[path] == nil {
                issues.append(ValidationIssue(
                    .error, code: "segment.openedNotCommitted",
                    message: "segment was opened but never committed in a session that stopped cleanly — "
                        + "its media was lost or is stranded in a .partial; run `screenreel recover`",
                    path: path))
            }
        }

        // Verify committed segments.
        for (path, segment) in journalSegments.sorted(by: { $0.key < $1.key }) {
            await verify(
                path: path, byteSize: segment.byteSize, sha256: segment.sha256,
                kind: "segment", layout: layout, issues: &issues)
            if let inspector = options.mediaInspector,
                let fileURL = try? layout.resolve(relativePath: path),
                FileManager.default.fileExists(atPath: fileURL.path)
            {
                let probe = await inspector.probe(url: fileURL, container: segment.container)
                if !probe.decodable {
                    issues.append(ValidationIssue(
                        .error, code: "segment.undecodable",
                        message: "committed segment failed decode inspection: \(probe.issues.joined(separator: "; "))",
                        path: path))
                } else if let durationNs = probe.durationNs {
                    let expected = segment.normalizedEndNs - segment.normalizedStartNs
                    if abs(durationNs - expected) > options.durationToleranceNs {
                        issues.append(ValidationIssue(
                            .warning, code: "segment.durationMismatch",
                            message: "container duration \(durationNs) ns vs descriptor \(expected) ns",
                            path: path))
                    }
                }
            }
        }

        // Verify committed event chunks, including record-level structure.
        for (path, chunk) in journalChunks.sorted(by: { $0.key < $1.key }) {
            if chunk.compression == .zstd {
                issues.append(ValidationIssue(
                    .error, code: "chunk.unsupportedCompression",
                    message: "chunk uses zstd compression, which this build does not support yet; "
                        + "use a newer Screenreel to read it (ADR 0003)",
                    path: path))
                continue
            }
            await verify(
                path: path, byteSize: chunk.byteSize, sha256: chunk.sha256,
                kind: "chunk", layout: layout, issues: &issues)
            verifyChunkRecords(chunk: chunk, path: path, layout: layout, issues: &issues)
        }

        // Manifest may lag the journal (legal crash window); the reverse is an
        // invariant violation.
        var manifestSegmentPaths = Set<String>()
        var manifestChunkPaths = Set<String>()
        var manifestAssetOwners: [String: UUID] = [:]
        for track in manifest.tracks {
            for segment in track.segments ?? [] {
                if let firstOwner = manifestAssetOwners[segment.path] {
                    issues.append(ValidationIssue(
                        .error, code: "manifest.duplicateAssetPath",
                        message: "asset path is referenced more than once (tracks \(firstOwner) and \(track.id))",
                        path: segment.path))
                } else {
                    manifestAssetOwners[segment.path] = track.id
                }
                manifestSegmentPaths.insert(segment.path)
                if journalSegments[segment.path] == nil {
                    issues.append(ValidationIssue(
                        .error, code: "manifest.unjournaledSegment",
                        message: "manifest references a segment with no segmentCommitted journal record",
                        path: segment.path))
                }
            }
            for chunk in track.eventChunks ?? [] {
                if let firstOwner = manifestAssetOwners[chunk.path] {
                    issues.append(ValidationIssue(
                        .error, code: "manifest.duplicateAssetPath",
                        message: "asset path is referenced more than once (tracks \(firstOwner) and \(track.id))",
                        path: chunk.path))
                } else {
                    manifestAssetOwners[chunk.path] = track.id
                }
                manifestChunkPaths.insert(chunk.path)
                if journalChunks[chunk.path] == nil {
                    issues.append(ValidationIssue(
                        .error, code: "manifest.unjournaledChunk",
                        message: "manifest references an event chunk with no eventChunkCommitted journal record",
                        path: chunk.path))
                }
            }
        }
        let lagging = Set(journalSegments.keys).subtracting(manifestSegmentPaths)
            .union(Set(journalChunks.keys).subtracting(manifestChunkPaths))
        if !lagging.isEmpty {
            issues.append(ValidationIssue(
                .info, code: "manifest.lagsJournal",
                message: "\(lagging.count) committed asset(s) not yet indexed in the manifest; recovery rebuilds the index"))
        }

        // Scan disk for orphans and partial tails.
        let known = Set(journalSegments.keys).union(journalChunks.keys)
        scanDisk(layout: layout, known: known, report: &report)
        for orphan in report.orphanCandidates {
            issues.append(ValidationIssue(
                .warning, code: "asset.orphan",
                message: "finalized file on disk has no journal record; `screenreel recover --attach-orphans` can attach it after inspection",
                path: orphan))
        }
        for partial in report.partialTails {
            issues.append(ValidationIssue(
                .info, code: "asset.partialTail",
                message: "interrupted write; recovery will quarantine it (never delete)",
                path: partial))
        }

        // Track summaries + the mic-absence gate.
        for track in manifest.tracks {
            let segs = (track.segments ?? []).filter { journalSegments[$0.path] != nil }
            let chunks = (track.eventChunks ?? []).filter { journalChunks[$0.path] != nil }
            // Also count journal-committed assets the manifest hasn't indexed
            // yet, keyed by track ID, so a crashed session reports reality.
            let journalOnlySegs = journalSegments.values.filter {
                $0.trackID == track.id && !manifestSegmentPaths.contains($0.path)
            }
            let journalOnlyChunks = journalChunks.values.filter {
                $0.trackID == track.id && !manifestChunkPaths.contains($0.path)
            }
            let allSegs = segs + journalOnlySegs
            let allChunks = chunks + journalOnlyChunks
            var bytes: Int64 = 0
            var byteSizeOverflow = false
            for size in allSegs.map(\.byteSize) + allChunks.map(\.byteSize) {
                let (sum, overflow) = bytes.addingReportingOverflow(size)
                if overflow {
                    byteSizeOverflow = true
                    bytes = size >= 0 ? Int64.max : Int64.min
                } else {
                    bytes = sum
                }
            }
            if byteSizeOverflow {
                issues.append(ValidationIssue(
                    .error, code: "descriptor.byteSizeOverflow",
                    message: "committed descriptor byte sizes overflow Int64",
                    path: track.id.uuidString))
            }
            let coverage = max(
                allSegs.map(\.normalizedEndNs).max() ?? 0,
                allChunks.map(\.endNs).max() ?? 0)
            report.tracks.append(TrackValidationSummary(
                trackID: track.id, type: track.type,
                committedSegments: allSegs.count,
                committedChunks: allChunks.count,
                committedBytes: bytes,
                coverageEndNs: coverage))

            // An event track was registered (permission was granted, capture
            // was intended) yet committed nothing across a cleanly stopped
            // session: cursor/click data silently went missing.
            if !track.type.isMedia, track.enabled ?? true,
                sessionStopped, allChunks.isEmpty
            {
                issues.append(ValidationIssue(
                    .warning, code: "events.noneCommitted",
                    message: "\(track.type.rawValue) track was registered but committed no event chunks"))
            }

            if track.type == .microphone, track.enabled ?? true {
                let sampleTotal = allSegs.compactMap { $0.audio?.sampleCount }.reduce(0, +)
                if allSegs.isEmpty || sampleTotal == 0 {
                    // The gate is scoped to the stop/export path (ACCEPTANCE
                    // §2 missing audio): a cleanly stopped mic-enabled project
                    // with no samples must not be called healthy. A session
                    // killed before its first segment boundary legitimately
                    // has nothing committed yet — warn, don't fail.
                    issues.append(ValidationIssue(
                        sessionStopped ? .error : .warning,
                        code: "audio.micMissing",
                        message: sessionStopped
                            ? "microphone capture was enabled but the mic track has no committed samples; "
                                + "this project must not be reported healthy (ACCEPTANCE_TESTS §2 missing audio)"
                            : "no mic samples committed before the session was interrupted"))
                }
            }
        }

        // Cross-track time-scale sanity: a stretched PTS ladder shows up as one track claiming
        // far more source time than BOTH its sibling tracks and the wall clock
        // observed between session start and the last commit. Warning only —
        // repair belongs to recovery, and only with two agreeing references.
        for anomaly in TrackTimeScale.detect(
            segments: Array(journalSegments.values), journal: journal.records)
        {
            var message = String(
                format: "%@ track committed %.2f s of source time — %.2f× its sibling "
                    + "consensus (%.2f s) and %.2f× the journal wall-clock span (%.2f s); "
                    + "its time mapping looks stretched",
                anomaly.trackType.rawValue,
                Double(anomaly.trackSpanNs) / 1e9, anomaly.factor,
                Double(anomaly.siblingConsensusNs) / 1e9, anomaly.factorVsWall,
                Double(anomaly.journalWallSpanNs) / 1e9)
            if anomaly.isAbsurd {
                message += ". The ratio exceeds \(Int(TrackTimeScale.absurdThreshold))× — the "
                    + "measurement itself is suspect, so automatic healing is refused"
            } else if anomaly.isHealable {
                message += ". `screenreel recover` can rewrite the time mapping "
                    + "(metadata only; raw media is never touched)"
            } else {
                message += ". The references disagree with each other, so recovery "
                    + "will not heal it automatically"
            }
            issues.append(ValidationIssue(
                .warning, code: "track.timeScaleAnomaly", message: message,
                path: anomaly.trackID.uuidString))
        }

        // Manifest duration vs committed coverage.
        if let claimed = manifest.durationNs {
            let coverage = report.tracks
                .filter { $0.type.isMedia }
                .map(\.coverageEndNs).max() ?? 0
            if abs(claimed - coverage) > options.durationToleranceNs {
                issues.append(ValidationIssue(
                    .warning, code: "manifest.durationMismatch",
                    message: "manifest durationNs \(claimed) vs committed coverage \(coverage)"))
            }
        }

        report.issues = issues.sorted { $0.severity > $1.severity }
        return report
    }

    // MARK: - Helpers

    private func verify(
        path: String, byteSize: Int64, sha256: String, kind: String,
        layout: ProjectLayout, issues: inout [ValidationIssue]
    ) async {
        let fileURL: URL
        do {
            fileURL = try layout.resolve(relativePath: path)
        } catch {
            issues.append(ValidationIssue(.error, code: "\(kind).unsafePath", message: "\(error)", path: path))
            return
        }
        let fm = FileManager.default
        guard fm.fileExists(atPath: fileURL.path) else {
            issues.append(ValidationIssue(
                .error, code: "\(kind).missing",
                message: "committed \(kind) is missing from disk", path: path))
            return
        }
        let actualSize = (try? fm.attributesOfItem(atPath: fileURL.path)[.size] as? Int64) ?? nil
        if let actualSize, actualSize != byteSize {
            issues.append(ValidationIssue(
                .error, code: "\(kind).sizeMismatch",
                message: "descriptor says \(byteSize) bytes, disk has \(actualSize)", path: path))
            return
        }
        if options.verifyChecksums {
            let actualHash = (try? Hashing.sha256HexOfFile(at: fileURL)) ?? ""
            if actualHash != sha256 {
                issues.append(ValidationIssue(
                    .error, code: "\(kind).checksumMismatch",
                    message: "SHA-256 mismatch (descriptor \(sha256.prefix(12))…, disk \(actualHash.prefix(12))…)",
                    path: path))
            }
        }
    }

    private func verifyChunkRecords(
        chunk: EventChunkDescriptor, path: String,
        layout: ProjectLayout, issues: inout [ValidationIssue]
    ) {
        guard let fileURL = try? layout.resolve(relativePath: path),
            let data = try? Data(contentsOf: fileURL),
            let text = String(data: data, encoding: .utf8)
        else { return }  // existence problems already reported
        var count = 0
        var lastSequence: UInt64?
        var lineNumber = 0
        for line in text.split(separator: "\n") {
            lineNumber += 1
            let record: EventRecord
            do {
                record = try EventRecord.parse(line: line, lineNumber: lineNumber)
            } catch {
                issues.append(ValidationIssue(
                    .error, code: "chunk.recordInvalid", message: "\(error)", path: path))
                continue
            }
            count += 1
            if let last = lastSequence, record.sequence <= last {
                issues.append(ValidationIssue(
                    .error, code: "chunk.sequenceNotMonotonic",
                    message: "event sequence \(record.sequence) after \(last) at line \(lineNumber)",
                    path: path))
            }
            lastSequence = record.sequence
            for problem in record.structuralProblems() {
                issues.append(ValidationIssue(
                    .warning, code: "chunk.recordStructural", message: problem, path: path))
            }
        }
        if count != chunk.recordCount {
            issues.append(ValidationIssue(
                .error, code: "chunk.countMismatch",
                message: "descriptor says \(chunk.recordCount) records, file has \(count)", path: path))
        }
    }

    private func scanDisk(layout: ProjectLayout, known: Set<String>, report: inout ValidationReport) {
        let fm = FileManager.default
        let mediaDirs = [
            layout.screenDirectory, layout.microphoneDirectory,
            layout.systemAudioDirectory, layout.cameraDirectory, layout.eventsDirectory,
        ]
        for dir in mediaDirs {
            guard let entries = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            else { continue }
            for entry in entries.sorted(by: { $0.path < $1.path }) {
                var isDirectory: ObjCBool = false
                fm.fileExists(atPath: entry.path, isDirectory: &isDirectory)
                if isDirectory.boolValue { continue }  // events/cursors handled separately
                let rel = layout.relativePath(of: entry)
                if entry.lastPathComponent.hasSuffix(ProjectLayout.partialSuffix) {
                    report.partialTails.append(rel)
                } else if entry.lastPathComponent.hasSuffix(".quarantined") {
                    continue  // already quarantined by a previous recovery
                } else if !known.contains(rel) {
                    report.orphanCandidates.append(rel)
                }
            }
        }
    }
}

// MARK: - Cross-track time scale

/// Cross-track duration sanity: a track whose PTS ladder is
/// stretched — double-rate device timestamps, high-refresh display stretch —
/// claims more committed *source* time than the session can physically have
/// contained. Detection compares each media track's committed source span
/// against two independent references: the sibling tracks' consensus and the
/// journal's wall-clock span between `sessionCreated` and the last commit.
///
/// The comparison is deliberately one-sided: a merely-short track (late
/// start, mid-session gap, early stop) is legal capture history and is never
/// flagged, because a track cannot legitimately contain MORE source time
/// than wall time elapsed.
public enum TrackTimeScale {
    /// A track counts as anomalous only past 1.5× — well beyond segment
    /// scheduling slack, well short of the 2× the known bug class produces.
    public static let anomalyThreshold = 1.5
    /// Past 8× the measurement itself is suspect: flag it, never auto-heal.
    public static let absurdThreshold = 8.0
    /// Spans and wall windows under one second carry too little signal for a
    /// ratio to mean anything (also keeps millisecond-built fixtures quiet).
    public static let minimumSpanNs: Int64 = 1_000_000_000

    public struct Anomaly: Sendable, Equatable {
        public var trackID: UUID
        public var trackType: TrackType
        /// Sum of committed segment source spans for this track.
        public var trackSpanNs: Int64
        /// Median of the sibling media tracks' committed source spans.
        public var siblingConsensusNs: Int64
        /// Wall-clock span between `sessionCreated` and the last commit.
        public var journalWallSpanNs: Int64
        /// Measured stretch factor vs the sibling consensus (> 1). This is
        /// the factor a heal divides the track's time mapping by.
        public var factor: Double
        public var factorVsWall: Double
        /// True when the two references corroborate each other within
        /// `anomalyThreshold` — the precondition for any repair.
        public var referencesAgree: Bool

        public var isAbsurd: Bool { factor > TrackTimeScale.absurdThreshold }
        /// Repairable: two agreeing references and a plausible ratio.
        public var isHealable: Bool { referencesAgree && !isAbsurd }
    }

    /// Wall-clock span of the recorded session per the trusted journal
    /// prefix, or nil when it cannot be measured.
    public static func journalWallSpanNs(records: [JournalRecord]) -> Int64? {
        guard
            let created = records.first(where: { $0.type == .sessionCreated }),
            let lastCommit = records.last(where: {
                $0.type == .segmentCommitted || $0.type == .eventChunkCommitted
            }),
            let start = RFC3339.date(from: created.wallTime),
            let end = RFC3339.date(from: lastCommit.wallTime)
        else { return nil }
        let span = end.timeIntervalSince(start)
        guard span.isFinite, span > 0 else { return nil }
        return Int64(span * 1_000_000_000)
    }

    /// Detect stretched media tracks among journal-committed segments.
    /// Returns nothing without at least one sibling AND a usable wall span:
    /// a single reference can never justify calling a track wrong.
    public static func detect(
        segments: [SegmentDescriptor], journal records: [JournalRecord]
    ) -> [Anomaly] {
        guard let wallSpanNs = journalWallSpanNs(records: records),
            wallSpanNs >= minimumSpanNs
        else { return [] }

        var tracks: [UUID: (type: TrackType, spanNs: Int64)] = [:]
        for segment in segments where segment.trackType.isMedia {
            let span = segment.sourceEndNs - segment.sourceStartNs
            guard span > 0 else { continue }
            tracks[segment.trackID, default: (segment.trackType, 0)].spanNs += span
        }
        guard tracks.count >= 2 else { return [] }  // no siblings, no consensus

        var anomalies: [Anomaly] = []
        for (trackID, track) in tracks.sorted(by: { $0.key.uuidString < $1.key.uuidString }) {
            guard track.spanNs >= minimumSpanNs else { continue }
            let siblingSpans = tracks.filter { $0.key != trackID }.map(\.value.spanNs).sorted()
            let consensusNs = median(ofSorted: siblingSpans)
            guard consensusNs > 0 else { continue }
            let factor = Double(track.spanNs) / Double(consensusNs)
            let factorVsWall = Double(track.spanNs) / Double(wallSpanNs)
            guard factor > anomalyThreshold, factorVsWall > anomalyThreshold else { continue }
            let referenceRatio = Double(consensusNs) / Double(wallSpanNs)
            anomalies.append(Anomaly(
                trackID: trackID,
                trackType: track.type,
                trackSpanNs: track.spanNs,
                siblingConsensusNs: consensusNs,
                journalWallSpanNs: wallSpanNs,
                factor: factor,
                factorVsWall: factorVsWall,
                referencesAgree: max(referenceRatio, 1 / referenceRatio) <= anomalyThreshold))
        }
        return anomalies
    }

    private static func median(ofSorted values: [Int64]) -> Int64 {
        guard !values.isEmpty else { return 0 }
        let mid = values.count / 2
        if values.count % 2 == 1 { return values[mid] }
        return (values[mid - 1] + values[mid]) / 2
    }
}
