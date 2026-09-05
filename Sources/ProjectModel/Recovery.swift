import Foundation

public struct RecoveryReport: Codable, Sendable {
    public var originalPath: String
    public var recoveredPath: String
    public var startedAt: String
    public var finishedAt: String
    public var toolVersion: String
    public var journalTrustedRecords: Int
    public var journalTruncationReason: String?
    public var recoveredSegments: Int
    public var recoveredChunks: Int
    /// Track IDs whose time mapping was rescaled by the cross-track duration
    /// heal (metadata only; raw media untouched).
    public var healedTracks: [String]
    public var rejectedAssets: [String]
    public var attachedOrphans: [String]
    public var unattachedOrphans: [String]
    public var quarantinedPartials: [String]
    public var rebuiltDurationNs: Int64
    public var issues: [ValidationIssue]
}

public struct RecoveryOptions: Sendable {
    /// Attach valid, contiguous, unjournaled tail segments to the recovered
    /// timeline. Off by default: orphans are preserved and reported, never
    /// silently assumed (`docs/PROJECT_FORMAT.md` §7.5).
    public var attachOrphans: Bool
    public var mediaInspector: MediaInspecting?
    /// Destination package; defaults to a sibling
    /// `<name> Recovered <timestamp>.screenreel`.
    public var destination: URL?

    public init(
        attachOrphans: Bool = false,
        mediaInspector: MediaInspecting? = nil,
        destination: URL? = nil
    ) {
        self.attachOrphans = attachOrphans
        self.mediaInspector = mediaInspector
        self.destination = destination
    }
}

/// Implements the recovery algorithm of `docs/PROJECT_FORMAT.md` §7.
///
/// The original package is opened strictly read-only; every repair happens in
/// a fresh recovered copy. The recovered copy receives a *fresh* journal that
/// describes exactly the recovered reality (only verified assets are
/// journaled), so the copy satisfies every invariant on its own; the original
/// journal — evidence included — is preserved verbatim both in the original
/// package and in the recovered copy's diagnostics snapshot.
///
/// The single exception to "read-only" is `.recovery-attempt.json`, the
/// terminal-status marker (metadata, written atomically, never raw media):
/// an attempt records itself before starting, a FAILED attempt is terminal —
/// recovery is never re-offered in a loop — and a successful attempt clears
/// the marker.
public enum Recovery {

    public static func recover(
        projectAt originalURL: URL,
        options: RecoveryOptions = RecoveryOptions()
    ) async throws -> RecoveryReport {
        let startedAt = RFC3339.now()
        let fm = FileManager.default
        let originalLayout = ProjectLayout(root: originalURL)

        // Refuse to race a live writer (a precondition refusal, not an
        // attempt — it leaves no marker).
        if let lock = try? SessionLock.read(from: originalLayout.sessionLockURL),
            lock.writerIsAlive()
        {
            throw ScreenreelError.sessionActive(path: originalURL.path, pid: lock.pid)
        }

        // Terminal-status gate: any surviving marker means a prior attempt
        // did not succeed (failed outright, or died mid-run). Existence
        // alone gates the retry, so even an unreadable marker counts.
        let markerURL = RecoveryAttemptMarker.url(in: originalLayout)
        if fm.fileExists(atPath: markerURL.path) {
            let previous = RecoveryAttemptMarker.read(from: originalLayout)
            throw RecoveryError.alreadyAttempted(
                path: originalURL.path,
                attemptStartedAt: previous?.startedAt,
                underlyingError: previous?.error)
        }

        // Destination collision is a caller error (pick another path), not a
        // failed attempt — checked before the marker is written.
        let destination = options.destination ?? defaultDestination(for: originalURL)
        guard !fm.fileExists(atPath: destination.path) else {
            throw ScreenreelError.ioFailed(operation: "create recovered package", path: destination.path, errno: EEXIST)
        }

        var marker = RecoveryAttemptMarker(
            startedAt: startedAt, outcome: .started, destination: destination.path)
        try AtomicFile.writeJSON(marker, to: markerURL)
        do {
            let report = try await performRecovery(
                projectAt: originalURL, originalLayout: originalLayout,
                destination: destination, startedAt: startedAt, options: options)
            // Success clears the marker. Best effort: if removal fails the
            // project errs toward "already attempted" — the safe direction.
            try? fm.removeItem(at: markerURL)
            return report
        } catch {
            marker.outcome = .failed
            marker.finishedAt = RFC3339.now()
            marker.error = "\(error)"
            // Best effort: losing the marker loses terminality, never data.
            try? AtomicFile.writeJSON(marker, to: markerURL)
            throw error
        }
    }

    private static func performRecovery(
        projectAt originalURL: URL,
        originalLayout: ProjectLayout,
        destination: URL,
        startedAt: String,
        options: RecoveryOptions
    ) async throws -> RecoveryReport {
        let fm = FileManager.default
        var issues: [ValidationIssue] = []

        // 1. Destination + metadata snapshot before any interpretation.
        let recoveredLayout = ProjectLayout(root: destination)
        for dir in recoveredLayout.initialDirectories {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        let snapshotDir = recoveredLayout.diagnosticsDirectory
            .appendingPathComponent("original-snapshot")
        try fm.createDirectory(at: snapshotDir, withIntermediateDirectories: true)
        for name in ["manifest.json", "journal.jsonl", "session.lock"] {
            let src = originalURL.appendingPathComponent(name)
            if fm.fileExists(atPath: src.path) {
                try FileCloner.clone(from: src, to: snapshotDir.appendingPathComponent(name))
            }
        }
        if fm.fileExists(atPath: originalLayout.captureLogURL.path) {
            try FileCloner.clone(
                from: originalLayout.captureLogURL,
                to: snapshotDir.appendingPathComponent("capture.jsonl"))
        }

        // 2. Journal trusted prefix.
        let scan: JournalScan
        if fm.fileExists(atPath: originalLayout.journalURL.path) {
            scan = try JournalReader.scan(url: originalLayout.journalURL)
        } else {
            scan = JournalScan(records: [], truncationReason: "journal.jsonl missing", truncatedAtLine: 1)
            issues.append(ValidationIssue(
                .error, code: "journal.missing",
                message: "journal.jsonl is missing; recovery is limited to orphan inspection"))
        }
        if let reason = scan.truncationReason, scan.truncatedAtLine != nil {
            issues.append(ValidationIssue(
                .warning, code: "journal.torn",
                message: "journal trusted prefix ends at line \(scan.truncatedAtLine ?? 0): \(reason)"))
        }

        // Original identity: the main manifest, else the newest readable
        // archived generation under .history/ (kept for exactly this crash
        // window, PROJECT_FORMAT §6), else journal + defaults.
        var originalManifest: Manifest? = {
            guard let data = try? Data(contentsOf: originalLayout.manifestURL) else { return nil }
            return try? Manifest.decode(from: data, path: originalLayout.manifestURL.path)
        }()
        if originalManifest == nil {
            if let archived = Self.newestHistoryManifest(in: originalLayout) {
                originalManifest = archived
                issues.append(ValidationIssue(
                    .warning, code: "manifest.recoveredFromHistory",
                    message: "main manifest unreadable; identity and clock anchor restored from .history/ generation \(archived.generation)"))
            } else {
                issues.append(ValidationIssue(
                    .warning, code: "manifest.unreadable",
                    message: "original manifest unreadable and no .history/ copy; identity rebuilt from the journal where possible"))
            }
        }

        // 3-4. Enumerate committed descriptors; verify; clone verified assets.
        // Rejected committed assets are preserved under quarantine/ so no
        // byte is lost, but they are excluded from the recovered index.
        var tracksFromJournal: [TrackDescriptor] = []
        var verifiedSegments: [SegmentDescriptor] = []
        var verifiedChunks: [EventChunkDescriptor] = []
        var rejected: [String] = []

        for record in scan.records {
            switch record.type {
            case .trackStarted:
                if let track = try? record.payload.decoded(as: TrackDescriptor.self) {
                    tracksFromJournal.append(track)
                }
            case .segmentCommitted:
                guard let segment = try? record.payload.decoded(as: SegmentDescriptor.self) else {
                    issues.append(ValidationIssue(
                        .error, code: "journal.payloadInvalid",
                        message: "segmentCommitted at sequence \(record.sequence) undecodable"))
                    continue
                }
                if await verifyAndClone(
                    path: segment.path, byteSize: segment.byteSize, sha256: segment.sha256,
                    container: segment.container, inspector: options.mediaInspector,
                    from: originalLayout, to: recoveredLayout, issues: &issues)
                {
                    verifiedSegments.append(segment)
                } else {
                    rejected.append(segment.path)
                    quarantineRejected(
                        path: segment.path, from: originalLayout, to: recoveredLayout,
                        issues: &issues)
                }
            case .eventChunkCommitted:
                guard let chunk = try? record.payload.decoded(as: EventChunkDescriptor.self) else {
                    issues.append(ValidationIssue(
                        .error, code: "journal.payloadInvalid",
                        message: "eventChunkCommitted at sequence \(record.sequence) undecodable"))
                    continue
                }
                if await verifyAndClone(
                    path: chunk.path, byteSize: chunk.byteSize, sha256: chunk.sha256,
                    container: nil, inspector: nil,
                    from: originalLayout, to: recoveredLayout, issues: &issues)
                {
                    verifiedChunks.append(chunk)
                } else {
                    rejected.append(chunk.path)
                    quarantineRejected(
                        path: chunk.path, from: originalLayout, to: recoveredLayout,
                        issues: &issues)
                }
            default:
                break
            }
        }

        // Cross-track duration heal: a
        // verified track whose PTS ladder is stretched gets its TIME MAPPING
        // rescaled in the recovered copy's descriptors — metadata only, raw
        // bytes and their checksums untouched — and only when two independent
        // references (sibling consensus AND journal wall span) agree on the
        // true time base. Absurd ratios (> 8×) are flagged, never healed.
        var healedAnomalies: [TrackTimeScale.Anomaly] = []
        for anomaly in TrackTimeScale.detect(segments: verifiedSegments, journal: scan.records) {
            guard anomaly.isHealable else {
                issues.append(ValidationIssue(
                    .warning, code: "track.timeScaleAnomaly",
                    message: String(
                        format: "%@ track source span is %.2f× its sibling consensus and %.2f× "
                            + "the journal wall span, but %@ — descriptors preserved verbatim, not healed",
                        anomaly.trackType.rawValue, anomaly.factor, anomaly.factorVsWall,
                        anomaly.isAbsurd
                            ? "the ratio is absurd (> \(Int(TrackTimeScale.absurdThreshold))×)"
                            : "the references disagree with each other"),
                    path: anomaly.trackID.uuidString))
                continue
            }
            for index in verifiedSegments.indices
            where verifiedSegments[index].trackID == anomaly.trackID {
                verifiedSegments[index] = rescaled(verifiedSegments[index], by: anomaly.factor)
            }
            healedAnomalies.append(anomaly)
            issues.append(ValidationIssue(
                .warning, code: "track.timeScaleHealed",
                message: String(
                    format: "%@ track time mapping rescaled by measured factor %.4f "
                        + "(sibling consensus %.2f s, journal wall span %.2f s agree); "
                        + "raw media untouched",
                    anomaly.trackType.rawValue, anomaly.factor,
                    Double(anomaly.siblingConsensusNs) / 1e9,
                    Double(anomaly.journalWallSpanNs) / 1e9),
                path: anomaly.trackID.uuidString))
        }

        // Cursor descriptors and edits are unjournaled metadata: clone whole.
        try cloneDirectoryContents(
            from: originalLayout.cursorsDirectory, to: recoveredLayout.cursorsDirectory)
        try cloneDirectoryContents(
            from: originalLayout.editsDirectory, to: recoveredLayout.editsDirectory)

        // 5-6. Orphans and partial tails on disk.
        var attachedOrphans: [String] = []
        var unattachedOrphans: [String] = []
        var quarantined: [String] = []
        let knownPaths = Set(verifiedSegments.map(\.path))
            .union(verifiedChunks.map(\.path))
            .union(rejected)
        var segmentsByTrack = Dictionary(grouping: verifiedSegments, by: \.trackID)

        for file in mediaFiles(in: originalLayout) {
            let rel = originalLayout.relativePath(of: file)
            if knownPaths.contains(rel) { continue }
            if file.lastPathComponent.hasSuffix(ProjectLayout.partialSuffix) {
                // Quarantine by rename in the recovered copy; original kept.
                let quarantinedName = file.lastPathComponent
                    .replacingOccurrences(of: ProjectLayout.partialSuffix, with: ".quarantined")
                let dst = recoveredLayout.root
                    .appendingPathComponent(originalLayout.relativePath(of: file.deletingLastPathComponent()))
                    .appendingPathComponent(quarantinedName)
                try FileCloner.clone(from: file, to: dst)
                quarantined.append(recoveredLayout.relativePath(of: dst))
                continue
            }
            // Finalized-looking orphan: preserve it in the recovered copy.
            let dst = recoveredLayout.root.appendingPathComponent(rel)
            try FileCloner.clone(from: file, to: dst)
            if options.attachOrphans,
                let inspector = options.mediaInspector,
                let attachment = await attachableOrphan(
                    relativePath: rel, url: dst, inspector: inspector,
                    tracks: tracksFromJournal, segmentsByTrack: segmentsByTrack)
            {
                verifiedSegments.append(attachment)
                segmentsByTrack[attachment.trackID, default: []].append(attachment)
                attachedOrphans.append(rel)
            } else {
                unattachedOrphans.append(rel)
                issues.append(ValidationIssue(
                    .warning, code: "asset.orphan",
                    message: options.attachOrphans
                        ? "orphan could not be safely attached (not a contiguous, decodable tail)"
                        : "finalized file has no journal record; re-run with --attach-orphans to attach after inspection",
                    path: rel))
            }
        }

        // 7-8. Fresh journal + rebuilt manifest describing recovered reality.
        // Identity preference: manifest (or .history), then the original
        // journal's own sessionCreated record — never invent an ID while a
        // recorded one exists.
        let journalProjectID = scan.records
            .first { $0.type == .sessionCreated }
            .flatMap { $0.payload["projectID"]?.stringValue }
            .flatMap(UUID.init(uuidString:))
        let projectID = originalManifest?.projectID ?? journalProjectID ?? UUID()

        let recoveredJournal = try JournalWriter(creatingAt: recoveredLayout.journalURL)
        try await recoveredJournal.append(
            type: .sessionCreated, timeNs: 0,
            payload: JSONValue(encoding: [
                "projectID": projectID.uuidString,
                "appVersion": ProjectSchema.toolVersion,
                "recoveredFrom": originalURL.lastPathComponent,
            ]))
        for track in tracksFromJournal {
            try await recoveredJournal.append(
                type: .trackStarted, timeNs: 0,
                payload: JournalPayload.trackStarted(track))
        }
        // Session history — pauses, gaps, device changes, faults — must stay
        // explicit in the recovered copy (ACCEPTANCE §2 Clock). Re-emitted in
        // original order; their timeNs values carry the timeline meaning.
        let historyTypes: Set<JournalRecordType> = [
            .pause, .resume, .discontinuity, .deviceChanged, .fault,
        ]
        for record in scan.records where historyTypes.contains(record.type) {
            try await recoveredJournal.append(
                type: record.type, timeNs: record.timeNs,
                payload: record.payload, durable: false)
        }
        // Every heal is documented in the recovered journal before the
        // rescaled descriptors it explains — the repair must be auditable.
        for anomaly in healedAnomalies {
            try await recoveredJournal.append(
                type: .fault, timeNs: 0,
                payload: JournalPayload.fault(
                    kind: "track.timeScaleHealed",
                    message: String(
                        format: "track %@ (%@) time mapping rescaled by measured factor %.4f; "
                            + "references: sibling consensus %d ns, journal wall span %d ns; "
                            + "raw media untouched",
                        anomaly.trackID.uuidString, anomaly.trackType.rawValue, anomaly.factor,
                        anomaly.siblingConsensusNs, anomaly.journalWallSpanNs)),
                durable: false)
        }
        var journaledSegments: [SegmentDescriptor] = []
        // Original scan order, with attached orphans at the end.
        for var segment in verifiedSegments {
            segment.commitSequence = await recoveredJournal.lastCommittedSequence + 1
            try await recoveredJournal.append(
                type: .segmentCommitted, timeNs: segment.normalizedEndNs,
                payload: JournalPayload.segmentCommitted(segment), durable: false)
            journaledSegments.append(segment)
        }
        var journaledChunks: [EventChunkDescriptor] = []
        for var chunk in verifiedChunks {
            chunk.commitSequence = await recoveredJournal.lastCommittedSequence + 1
            try await recoveredJournal.append(
                type: .eventChunkCommitted, timeNs: chunk.endNs,
                payload: JournalPayload.eventChunkCommitted(chunk), durable: false)
            journaledChunks.append(chunk)
        }

        var manifest = rebuildManifest(
            original: originalManifest,
            projectID: projectID,
            tracksFromJournal: tracksFromJournal,
            segments: journaledSegments,
            chunks: journaledChunks)
        manifest.modifiedAt = RFC3339.now()
        let durationNs = manifest.durationNs ?? 0

        try await recoveredJournal.append(
            type: .validationCompleted, timeNs: durationNs,
            payload: JSONValue(encoding: [
                "recoveredSegments": .integer(Int64(journaledSegments.count)),
                "recoveredChunks": .integer(Int64(journaledChunks.count)),
                "rejected": .integer(Int64(rejected.count)),
                "attachedOrphans": .integer(Int64(attachedOrphans.count)),
                "quarantined": .integer(Int64(quarantined.count)),
            ] as [String: JSONValue]))

        try AtomicFile.writeJSON(manifest, to: recoveredLayout.manifestURL)
        try AtomicFile.syncDirectory(recoveredLayout.root)

        // 9-10. Report. Derived assets rebuild lazily; nothing else to do.
        let report = RecoveryReport(
            originalPath: originalURL.path,
            recoveredPath: destination.path,
            startedAt: startedAt,
            finishedAt: RFC3339.now(),
            toolVersion: ProjectSchema.toolVersion,
            journalTrustedRecords: scan.records.count,
            journalTruncationReason: scan.truncationReason,
            recoveredSegments: journaledSegments.count,
            recoveredChunks: journaledChunks.count,
            healedTracks: healedAnomalies.map { $0.trackID.uuidString },
            rejectedAssets: rejected,
            attachedOrphans: attachedOrphans,
            unattachedOrphans: unattachedOrphans,
            quarantinedPartials: quarantined,
            rebuiltDurationNs: durationNs,
            issues: issues)
        let reportName = "recovery-\(startedAt.replacingOccurrences(of: ":", with: "-")).json"
        try AtomicFile.writeJSON(
            report, to: recoveredLayout.diagnosticsDirectory.appendingPathComponent(reportName))
        return report
    }

    // MARK: - Steps

    /// Divide a descriptor's time mapping by the measured stretch factor.
    /// Only the four time fields change: path, byte size, and SHA-256 still
    /// describe the untouched raw bytes. Boundaries shared between segments
    /// rescale to identical values (same input → same output), so track
    /// contiguity survives. `timingEstimated` marks the times as
    /// reconstructed, not measured (§7.5 "never assume").
    private static func rescaled(
        _ segment: SegmentDescriptor, by factor: Double
    ) -> SegmentDescriptor {
        func scale(_ valueNs: Int64) -> Int64 {
            Int64((Double(valueNs) / factor).rounded())
        }
        var healed = segment
        healed.sourceStartNs = scale(segment.sourceStartNs)
        healed.sourceEndNs = scale(segment.sourceEndNs)
        healed.normalizedStartNs = scale(segment.normalizedStartNs)
        healed.normalizedEndNs = scale(segment.normalizedEndNs)
        healed.timingEstimated = true
        return healed
    }

    private static func defaultDestination(for original: URL) -> URL {
        let base = original.deletingPathExtension().lastPathComponent
        let stamp = RFC3339.now()
            .replacingOccurrences(of: ":", with: "-")
            .prefix(19)
        return original.deletingLastPathComponent()
            .appendingPathComponent("\(base) Recovered \(stamp).screenreel")
    }

    /// Returns true when the committed asset verifies (exists, size, hash,
    /// optional decode) and was cloned into the recovered package.
    private static func verifyAndClone(
        path: String, byteSize: Int64, sha256: String,
        container: MediaContainer?, inspector: MediaInspecting?,
        from original: ProjectLayout, to recovered: ProjectLayout,
        issues: inout [ValidationIssue]
    ) async -> Bool {
        guard let src = try? original.resolve(relativePath: path) else {
            issues.append(ValidationIssue(.error, code: "asset.unsafePath", message: path))
            return false
        }
        let fm = FileManager.default
        guard fm.fileExists(atPath: src.path) else {
            issues.append(ValidationIssue(
                .error, code: "asset.missing", message: "committed asset missing", path: path))
            return false
        }
        let size = (try? fm.attributesOfItem(atPath: src.path)[.size] as? Int64) ?? nil
        guard size == byteSize else {
            issues.append(ValidationIssue(
                .error, code: "asset.sizeMismatch",
                message: "descriptor \(byteSize) bytes vs disk \(size.map(String.init) ?? "?")",
                path: path))
            return false
        }
        guard let hash = try? Hashing.sha256HexOfFile(at: src), hash == sha256 else {
            issues.append(ValidationIssue(
                .error, code: "asset.checksumMismatch", message: "SHA-256 mismatch", path: path))
            return false
        }
        if let inspector, let container {
            let probe = await inspector.probe(url: src, container: container)
            guard probe.decodable else {
                issues.append(ValidationIssue(
                    .error, code: "asset.undecodable",
                    message: probe.issues.joined(separator: "; "), path: path))
                return false
            }
        }
        do {
            try FileCloner.clone(from: src, to: recovered.root.appendingPathComponent(path))
            return true
        } catch {
            issues.append(ValidationIssue(
                .error, code: "asset.cloneFailed", message: "\(error)", path: path))
            return false
        }
    }

    /// A committed asset that failed verification still gets cloned into
    /// `quarantine/` in the recovered copy — evidence is never dropped, and a
    /// failure to preserve it must be visible, never silent.
    private static func quarantineRejected(
        path: String, from original: ProjectLayout, to recovered: ProjectLayout,
        issues: inout [ValidationIssue]
    ) {
        guard let src = try? original.resolve(relativePath: path),
            FileManager.default.fileExists(atPath: src.path)
        else { return }
        let dst = recovered.root
            .appendingPathComponent("quarantine")
            .appendingPathComponent(path)
        do {
            try FileCloner.clone(from: src, to: dst)
        } catch {
            issues.append(ValidationIssue(
                .error, code: "asset.quarantineFailed",
                message: "rejected asset could not be preserved under quarantine/ (\(error)); "
                    + "the original package still holds the only copy — do not delete it",
                path: path))
        }
    }

    /// Newest readable archived manifest generation, if any.
    private static func newestHistoryManifest(in layout: ProjectLayout) -> Manifest? {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: layout.historyDirectory, includingPropertiesForKeys: nil)
        else { return nil }
        return entries
            .filter { $0.lastPathComponent.hasPrefix("manifest-") }
            .compactMap { url -> Manifest? in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return try? Manifest.decode(from: data, path: url.path)
            }
            .max { $0.generation < $1.generation }
    }

    private static func cloneDirectoryContents(from source: URL, to destination: URL) throws {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: source, includingPropertiesForKeys: nil)
        else { return }
        for entry in entries {
            try FileCloner.clone(
                from: entry, to: destination.appendingPathComponent(entry.lastPathComponent))
        }
    }

    private static func mediaFiles(in layout: ProjectLayout) -> [URL] {
        let fm = FileManager.default
        let dirs = [
            layout.screenDirectory, layout.microphoneDirectory,
            layout.systemAudioDirectory, layout.cameraDirectory, layout.eventsDirectory,
        ]
        var files: [URL] = []
        for dir in dirs {
            guard let entries = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            else { continue }
            for entry in entries.sorted(by: { $0.path < $1.path }) {
                var isDirectory: ObjCBool = false
                fm.fileExists(atPath: entry.path, isDirectory: &isDirectory)
                if !isDirectory.boolValue { files.append(entry) }
            }
        }
        return files
    }

    /// An orphan may attach only when it parses as the next contiguous
    /// sequence of an existing media track and decodes cleanly. Times are
    /// derived from the previous committed end plus the probed duration.
    private static func attachableOrphan(
        relativePath: String, url: URL, inspector: MediaInspecting,
        tracks: [TrackDescriptor],
        segmentsByTrack: [UUID: [SegmentDescriptor]]
    ) async -> SegmentDescriptor? {
        guard let parsed = parseSegmentFileName(relativePath) else { return nil }
        guard let track = tracks.first(where: { candidate in
            candidate.type == parsed.type
                && (parsed.type != .screen || candidate.displayID == parsed.displayID)
        }) else { return nil }
        let committed = (segmentsByTrack[track.id] ?? []).sorted { $0.sequenceInTrack < $1.sequenceInTrack }
        let expectedNext = (committed.last?.sequenceInTrack ?? 0) + 1
        guard parsed.sequence == expectedNext else { return nil }

        let container: MediaContainer = parsed.type.isAudio ? .caf : .mov
        let probe = await inspector.probe(url: url, container: container)
        guard probe.decodable, let durationNs = probe.durationNs, durationNs > 0 else { return nil }

        let fm = FileManager.default
        guard let size = (try? fm.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? nil,
            let hash = try? Hashing.sha256HexOfFile(at: url)
        else { return nil }

        let previousEnd = committed.last?.normalizedEndNs ?? 0
        let previousSourceEnd = committed.last?.sourceEndNs ?? 0
        let codec: MediaCodec = committed.last?.codec ?? (parsed.type.isAudio ? .pcmFloat32 : .hevc)
        return SegmentDescriptor(
            trackID: track.id,
            trackType: parsed.type,
            path: relativePath,
            sequenceInTrack: parsed.sequence,
            container: container,
            codec: codec,
            video: probe.video,
            audio: probe.audio,
            sourceStartNs: previousSourceEnd,
            sourceEndNs: previousSourceEnd + durationNs,
            normalizedStartNs: previousEnd,
            normalizedEndNs: previousEnd + durationNs,
            byteSize: size,
            sha256: hash,
            discontinuityBefore: nil,  // unknown — a real gap may precede it
            timingEstimated: true,  // times derived, not measured (§7.5 "never assume")
            commitSequence: 0)  // assigned when journaled into the recovered copy
    }

    static func parseSegmentFileName(_ relativePath: String)
        -> (type: TrackType, displayID: Int?, sequence: Int)?
    {
        let name = (relativePath as NSString).lastPathComponent
        if name.hasPrefix("display-") {
            let parts = name.dropFirst("display-".count).split(separator: "-")
            guard parts.count == 2,
                let display = Int(parts[0]),
                let seq = Int(parts[1].split(separator: ".").first ?? "")
            else { return nil }
            return (.screen, display, seq)
        }
        if name.hasPrefix("mic-"), let seq = sequenceSuffix(name, prefix: "mic-") {
            return (.microphone, nil, seq)
        }
        if name.hasPrefix("system-"), let seq = sequenceSuffix(name, prefix: "system-") {
            return (.systemAudio, nil, seq)
        }
        if name.hasPrefix("camera-"), let seq = sequenceSuffix(name, prefix: "camera-") {
            return (.camera, nil, seq)
        }
        return nil
    }

    private static func sequenceSuffix(_ name: String, prefix: String) -> Int? {
        Int(name.dropFirst(prefix.count).split(separator: ".").first ?? "")
    }

    private static func rebuildManifest(
        original: Manifest?,
        projectID: UUID,
        tracksFromJournal: [TrackDescriptor],
        segments: [SegmentDescriptor],
        chunks: [EventChunkDescriptor]
    ) -> Manifest {
        let segmentsByTrack = Dictionary(grouping: segments, by: \.trackID)
        let chunksByTrack = Dictionary(grouping: chunks, by: \.trackID)
        var tracks: [TrackDescriptor] = []
        var maxEndNs: Int64 = 0
        for var track in tracksFromJournal {
            let trackSegments = (segmentsByTrack[track.id] ?? [])
                .sorted { $0.sequenceInTrack < $1.sequenceInTrack }
            let trackChunks = (chunksByTrack[track.id] ?? [])
                .sorted { $0.sequenceInTrack < $1.sequenceInTrack }
            track.segments = trackSegments.isEmpty ? nil : trackSegments
            track.eventChunks = trackChunks.isEmpty ? nil : trackChunks
            if track.type.isMedia, let end = trackSegments.map(\.normalizedEndNs).max() {
                maxEndNs = max(maxEndNs, end)
            }
            tracks.append(track)
        }

        var manifest = Manifest(
            projectID: projectID,
            createdAt: original?.createdAt ?? RFC3339.now(),
            state: .recoverable,
            clock: original?.clock
                ?? ClockAnchor(
                    originContinuousTicks: 0, originAbsoluteTicks: 0,
                    timebaseNumer: 1, timebaseDenom: 1,
                    originWallTime: original?.createdAt ?? RFC3339.now()),
            capture: original?.capture,
            tracks: tracks,
            timeline: original?.timeline,
            durationNs: maxEndNs,
            generation: (original?.generation ?? 0) + 1)
        manifest.appVersion = ProjectSchema.toolVersion
        return manifest
    }
}

extension TrackType {
    var isAudio: Bool {
        self == .microphone || self == .systemAudio
    }
}

/// `.recovery-attempt.json` — the terminal recovery-status marker: a
/// failed recovery is terminal, never retried in a loop. Written atomically into the ORIGINAL package when an attempt
/// starts, rewritten with the failure on error, and removed by a successful
/// recovery — so a broken project is diagnosed once instead of being
/// re-offered for recovery in a loop. Metadata only; never raw media.
public struct RecoveryAttemptMarker: Codable, Sendable, Equatable {
    public enum Outcome: String, Codable, Sendable {
        /// Attempt in flight (or the process died mid-attempt — also
        /// terminal: the attempt did not succeed).
        case started
        case failed
    }

    public var schemaVersion: Int
    public var startedAt: String
    public var finishedAt: String?
    public var outcome: Outcome
    public var error: String?
    public var destination: String
    public var toolVersion: String

    public init(startedAt: String, outcome: Outcome, destination: String) {
        self.schemaVersion = ProjectSchema.currentVersion
        self.startedAt = startedAt
        self.finishedAt = nil
        self.outcome = outcome
        self.error = nil
        self.destination = destination
        self.toolVersion = ProjectSchema.toolVersion
    }

    public static let fileName = ".recovery-attempt.json"

    public static func url(in layout: ProjectLayout) -> URL {
        layout.root.appendingPathComponent(fileName)
    }

    /// Nil when absent or unreadable. Existence alone gates retries, so a
    /// corrupt marker still counts as a prior attempt.
    public static func read(from layout: ProjectLayout) -> RecoveryAttemptMarker? {
        guard let data = try? Data(contentsOf: url(in: layout)) else { return nil }
        return try? JSONDecoder().decode(RecoveryAttemptMarker.self, from: data)
    }
}

/// Errors specific to the recovery workflow.
public enum RecoveryError: Error, Sendable, CustomStringConvertible {
    /// A previous recovery attempt on this package did not succeed; recovery
    /// is terminal and must not retry in a loop.
    case alreadyAttempted(path: String, attemptStartedAt: String?, underlyingError: String?)

    public var description: String {
        switch self {
        case .alreadyAttempted(let path, let startedAt, let underlying):
            var message = "Recovery of \(path) was already attempted, see diagnostics"
            if let startedAt { message += ": the attempt started \(startedAt)" }
            if let underlying { message += " and failed with: \(underlying)" }
            message += ". The original package is untouched and "
                + "\(RecoveryAttemptMarker.fileName) preserves the attempt record; "
                + "remove that file to retry after resolving the cause."
            return message
        }
    }
}
