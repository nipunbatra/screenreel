import XCTest

@testable import ProjectModel

/// Deterministic fake media probe so validator/recovery logic can be tested
/// without real containers (ProjectModel must stay media-framework-free).
struct FakeInspector: MediaInspecting {
    var decodable = true
    var durationNs: Int64 = 1_000_000_000

    func probe(url: URL, container: MediaContainer) async -> MediaProbe {
        MediaProbe(
            decodable: decodable,
            durationNs: durationNs,
            audio: container == .caf
                ? AudioFormatInfo(sampleRate: 48_000, channels: 1, sampleCount: 48_000)
                : nil,
            issues: decodable ? [] : ["fake failure"])
    }
}

/// Builds a small, fully-committed fake project exercising the same commit
/// protocol as capture: files on disk, hash-chained journal records, manifest
/// index, clean finalization.
enum TestProject {
    struct Built {
        var url: URL
        var layout: ProjectLayout
        var screenTrackID: UUID
        var micTrackID: UUID
    }

    @discardableResult
    static func build(
        at url: URL,
        screenSegments: Int = 2,
        micSegments: Int = 2,
        finalize: Bool = true
    ) async throws -> Built {
        let clock = ClockAnchor(
            originContinuousTicks: 100, originAbsoluteTicks: 100,
            timebaseNumer: 125, timebaseDenom: 3, originWallTime: RFC3339.now())
        let created = try await ProjectPackage.create(at: url, clock: clock)
        let layout = created.layout
        let journal = created.journal
        let store = created.manifestStore

        let screenTrack = TrackDescriptor(type: .screen, displayID: 1, cursorBaked: false)
        let micTrack = TrackDescriptor(type: .microphone, deviceName: "Fake Mic")
        for track in [screenTrack, micTrack] {
            try await journal.append(
                type: .trackStarted, timeNs: 0, payload: JournalPayload.trackStarted(track))
            _ = try await store.save { $0.tracks.append(track) }
        }

        func commit(
            track: TrackDescriptor, type: TrackType, sequence: Int, startNs: Int64
        ) async throws {
            let name = ProjectLayout.segmentFileName(
                type: type, displayID: track.displayID, sequence: sequence)
            let fileURL = layout.mediaDirectory(for: type).appendingPathComponent(name)
            let contents = Data("fake-\(type.rawValue)-\(sequence)".utf8)
            try contents.write(to: fileURL)
            let endNs = startNs + 4_000_000_000
            var descriptor = SegmentDescriptor(
                trackID: track.id, trackType: type,
                path: layout.relativePath(of: fileURL),
                sequenceInTrack: sequence,
                container: type == .screen ? .mov : .caf,
                codec: type == .screen ? .hevc : .pcmFloat32,
                audio: type == .microphone
                    ? AudioFormatInfo(sampleRate: 48_000, channels: 1, sampleCount: 192_000)
                    : nil,
                sourceStartNs: startNs, sourceEndNs: endNs,
                normalizedStartNs: startNs, normalizedEndNs: endNs,
                byteSize: Int64(contents.count),
                sha256: Hashing.sha256Hex(contents),
                commitSequence: 0)
            descriptor.commitSequence = await journal.lastCommittedSequence + 1
            try await journal.append(
                type: .segmentCommitted, timeNs: endNs,
                payload: JournalPayload.segmentCommitted(descriptor))
            _ = try await store.save { $0.appendSegment(descriptor) }
        }

        for index in 0..<screenSegments {
            try await commit(
                track: screenTrack, type: .screen,
                sequence: index + 1, startNs: Int64(index) * 4_000_000_000)
        }
        for index in 0..<micSegments {
            try await commit(
                track: micTrack, type: .microphone,
                sequence: index + 1, startNs: Int64(index) * 4_000_000_000)
        }

        // One committed cursor event chunk.
        let events = (0..<3).map { index in
            EventRecord(
                sequence: UInt64(index + 1), timeNs: Int64(index) * 1_000_000,
                type: .cursorMove, displayID: 1, xPx: Double(index), yPx: 0,
                cursorID: "arrow-1", buttons: 0)
        }
        var chunkText = ""
        for event in events { chunkText += try event.jsonlLine() + "\n" }
        let chunkData = Data(chunkText.utf8)
        let chunkURL = layout.eventsDirectory.appendingPathComponent(
            ProjectLayout.chunkFileName(kind: .cursor, sequence: 1, compression: .none))
        try chunkData.write(to: chunkURL)
        let cursorTrack = TrackDescriptor(type: .cursorEvents)
        try await journal.append(
            type: .trackStarted, timeNs: 0, payload: JournalPayload.trackStarted(cursorTrack))
        _ = try await store.save { $0.tracks.append(cursorTrack) }
        var chunk = EventChunkDescriptor(
            trackID: cursorTrack.id, kind: .cursor,
            path: layout.relativePath(of: chunkURL),
            sequenceInTrack: 1, compression: .none,
            firstEventSequence: 1, lastEventSequence: 3,
            startNs: 0, endNs: 2_000_000,
            recordCount: 3, byteSize: Int64(chunkData.count),
            sha256: Hashing.sha256Hex(chunkData), commitSequence: 0)
        chunk.commitSequence = await journal.lastCommittedSequence + 1
        try await journal.append(
            type: .eventChunkCommitted, timeNs: chunk.endNs,
            payload: JournalPayload.eventChunkCommitted(chunk))
        _ = try await store.save { $0.appendEventChunk(chunk) }

        if finalize {
            try await journal.append(
                type: .sessionStopped, timeNs: 0, payload: JournalPayload.empty())
            try await journal.append(
                type: .validationCompleted, timeNs: 0, payload: JournalPayload.empty())
            try await journal.append(
                type: .sessionFinalized, timeNs: 0, payload: JournalPayload.empty())
            _ = try await store.save { $0.state = .ready }
            try? FileManager.default.removeItem(at: layout.sessionLockURL)
        } else {
            // Simulate a crashed writer: lock present, writer gone.
            var lock = SessionLock(sessionID: created.sessionID)
            lock.pid = 99999
            lock.processStartMarker = "99999:1.1"
            try lock.write(to: layout.sessionLockURL)
        }
        return Built(
            url: url, layout: layout,
            screenTrackID: screenTrack.id, micTrackID: micTrack.id)
    }
}

final class ValidatorRecoveryTests: XCTestCase {
    private var directory: URL!

    override func setUp() {
        super.setUp()
        AtomicFile.fullFsync = false
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("aks-vr-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        AtomicFile.fullFsync = true
        super.tearDown()
    }

    private var projectURL: URL { directory.appendingPathComponent("p.aks") }

    func testHealthyProjectValidates() async throws {
        try await TestProject.build(at: projectURL)
        let report = await Validator().validate(projectAt: projectURL)
        XCTAssertTrue(report.isHealthy, "\(report.issues)")
        XCTAssertTrue(report.journalFinalized)
        XCTAssertFalse(report.needsRecovery)
        XCTAssertEqual(report.tracks.count, 3)
    }

    func testCorruptedSegmentFailsChecksum() async throws {
        let built = try await TestProject.build(at: projectURL)
        let target = built.layout.screenDirectory
            .appendingPathComponent("display-1-000001.mov")
        var data = try Data(contentsOf: target)
        data[0] ^= 0xFF
        try data.write(to: target)

        let report = await Validator().validate(projectAt: projectURL)
        XCTAssertFalse(report.isHealthy)
        XCTAssertTrue(report.issues.contains { $0.code == "segment.checksumMismatch" })
    }

    func testMissingAndResizedSegments() async throws {
        let built = try await TestProject.build(at: projectURL)
        try FileManager.default.removeItem(
            at: built.layout.screenDirectory.appendingPathComponent("display-1-000001.mov"))
        let resized = built.layout.microphoneDirectory.appendingPathComponent("mic-000001.caf")
        try Data("short".utf8).write(to: resized)

        let report = await Validator().validate(projectAt: projectURL)
        XCTAssertTrue(report.issues.contains { $0.code == "segment.missing" })
        XCTAssertTrue(report.issues.contains { $0.code == "segment.sizeMismatch" })
    }

    func testManifestReferencingUnjournaledSegmentIsError() async throws {
        let built = try await TestProject.build(at: projectURL)
        // Forge a manifest entry with no journal backing.
        let loaded = try ProjectPackage.load(at: projectURL)
        var manifest = loaded.manifest
        let forged = SegmentDescriptor(
            trackID: built.screenTrackID, trackType: .screen,
            path: "raw/screen/display-1-000099.mov", sequenceInTrack: 99,
            container: .mov, codec: .hevc,
            sourceStartNs: 0, sourceEndNs: 1, normalizedStartNs: 0, normalizedEndNs: 1,
            byteSize: 1, sha256: String(repeating: "a", count: 64), commitSequence: 999)
        manifest.appendSegment(forged)
        try AtomicFile.writeJSON(manifest, to: built.layout.manifestURL)

        let report = await Validator().validate(projectAt: projectURL)
        XCTAssertTrue(report.issues.contains { $0.code == "manifest.unjournaledSegment" })
    }

    func testOrphansAndPartialsAreReported() async throws {
        let built = try await TestProject.build(at: projectURL)
        try Data("orphan".utf8).write(
            to: built.layout.screenDirectory.appendingPathComponent("display-1-000003.mov"))
        try Data("tail".utf8).write(
            to: built.layout.microphoneDirectory
                .appendingPathComponent("mic-000003.caf.partial"))

        let report = await Validator().validate(projectAt: projectURL)
        XCTAssertEqual(report.orphanCandidates, ["raw/screen/display-1-000003.mov"])
        XCTAssertEqual(report.partialTails, ["raw/microphone/mic-000003.caf.partial"])
    }

    func testMicEnabledButEmptyIsError() async throws {
        try await TestProject.build(at: projectURL, micSegments: 0)
        let report = await Validator().validate(projectAt: projectURL)
        XCTAssertFalse(report.isHealthy)
        XCTAssertTrue(report.issues.contains { $0.code == "audio.micMissing" && $0.severity == .error })
    }

    /// The stop/export scope of the mic gate: a session killed before any mic
    /// segment committed warns but does not fail validation.
    func testMicEmptyOnCrashedSessionIsOnlyWarning() async throws {
        try await TestProject.build(at: projectURL, micSegments: 0, finalize: false)
        let report = await Validator().validate(projectAt: projectURL)
        let micIssues = report.issues.filter { $0.code == "audio.micMissing" }
        XCTAssertEqual(micIssues.map(\.severity), [.warning])
        XCTAssertFalse(report.issues.contains { $0.severity == .error }, "\(report.issues)")
    }

    /// After a clean stop, a journaled segmentOpened without a matching
    /// commit means media was lost — that must be an error, not info.
    func testOpenedButNeverCommittedAfterCleanStopIsError() async throws {
        let built = try await TestProject.build(at: projectURL, finalize: false)
        let journal = try JournalWriter(resumingAt: built.layout.journalURL)
        try await journal.append(
            type: .segmentOpened, timeNs: 0,
            payload: JournalPayload.segmentOpened(
                trackID: built.screenTrackID,
                path: "raw/screen/display-1-000099.mov",
                sequenceInTrack: 99))
        try await journal.append(
            type: .sessionStopped, timeNs: 0, payload: JournalPayload.empty())
        try? FileManager.default.removeItem(at: built.layout.sessionLockURL)

        let report = await Validator().validate(projectAt: projectURL)
        XCTAssertTrue(report.issues.contains { $0.code == "segment.openedNotCommitted" })
        XCTAssertFalse(report.isHealthy)
    }

    func testRecoveryOfCrashedProject() async throws {
        let built = try await TestProject.build(at: projectURL, finalize: false)
        // A torn tail and a corrupted committed segment.
        try Data("tail".utf8).write(
            to: built.layout.screenDirectory
                .appendingPathComponent("display-1-000003.mov.partial"))
        let corrupt = built.layout.microphoneDirectory.appendingPathComponent("mic-000002.caf")
        var data = try Data(contentsOf: corrupt)
        data[0] ^= 0xFF
        try data.write(to: corrupt)

        let originalJournal = try Data(contentsOf: built.layout.journalURL)
        let recoveredURL = directory.appendingPathComponent("recovered.aks")
        let report = try await Recovery.recover(
            projectAt: projectURL,
            options: RecoveryOptions(destination: recoveredURL))

        XCTAssertEqual(report.recoveredSegments, 3)  // 2 screen + 1 valid mic
        XCTAssertEqual(report.rejectedAssets, ["raw/microphone/mic-000002.caf"])
        XCTAssertEqual(report.quarantinedPartials, ["raw/screen/display-1-000003.mov.quarantined"])

        // Original untouched: journal bytes identical, partial still present.
        XCTAssertEqual(try Data(contentsOf: built.layout.journalURL), originalJournal)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: built.layout.screenDirectory
                .appendingPathComponent("display-1-000003.mov.partial").path))

        // Recovered copy: recoverable state, valid journal, metadata snapshot.
        let recovered = try ProjectPackage.load(at: recoveredURL)
        XCTAssertEqual(recovered.manifest.state, .recoverable)
        XCTAssertNil(recovered.journal.truncationReason)
        let snapshot = ProjectLayout(root: recoveredURL).diagnosticsDirectory
            .appendingPathComponent("original-snapshot/journal.jsonl")
        XCTAssertEqual(try Data(contentsOf: snapshot), originalJournal)

        // The recovered copy has no unexplained validation errors: the
        // rejected mic segment was excluded from its manifest entirely.
        let validation = await Validator().validate(projectAt: recoveredURL)
        XCTAssertTrue(validation.isHealthy, "\(validation.issues)")
    }

    func testRecoveryRefusesLiveWriter() async throws {
        let built = try await TestProject.build(at: projectURL, finalize: false)
        // Rewrite the lock to name this live test process.
        let lock = SessionLock(sessionID: UUID())
        try lock.write(to: built.layout.sessionLockURL)
        do {
            _ = try await Recovery.recover(projectAt: projectURL)
            XCTFail("expected sessionActive")
        } catch let error as AksError {
            guard case .sessionActive = error else {
                return XCTFail("expected sessionActive, got \(error)")
            }
        }
    }

    func testRecoveryAttachesContiguousOrphanTail() async throws {
        let built = try await TestProject.build(at: projectURL, finalize: false)
        // A finalized-but-unjournaled next mic segment (crash between rename
        // and journal append).
        let orphan = built.layout.microphoneDirectory.appendingPathComponent("mic-000003.caf")
        try Data("orphan tail bytes".utf8).write(to: orphan)

        let recoveredURL = directory.appendingPathComponent("recovered-attach.aks")
        let report = try await Recovery.recover(
            projectAt: projectURL,
            options: RecoveryOptions(
                attachOrphans: true,
                mediaInspector: FakeInspector(),
                destination: recoveredURL))
        XCTAssertEqual(report.attachedOrphans, ["raw/microphone/mic-000003.caf"])

        let recovered = try ProjectPackage.load(at: recoveredURL)
        let micTrack = recovered.manifest.tracks.first { $0.id == built.micTrackID }
        XCTAssertEqual(micTrack?.segments?.count, 3)
        // The attachment is journaled in the recovered copy, keeping the
        // "manifest references only journaled segments" invariant.
        let journaledPaths = recovered.journal.records(ofType: .segmentCommitted)
            .compactMap { try? $0.payload.decoded(as: SegmentDescriptor.self).path }
        XCTAssertTrue(journaledPaths.contains("raw/microphone/mic-000003.caf"))

        let validation = await Validator().validate(projectAt: recoveredURL)
        XCTAssertTrue(validation.isHealthy, "\(validation.issues)")
    }

    /// A torn main manifest must not cost the project its identity, clock
    /// anchor, or session history: recovery falls back to .history/ and the
    /// journal, and re-emits pause/resume records into the recovered journal.
    func testRecoveryPreservesIdentityAndHistoryWithTornManifest() async throws {
        let built = try await TestProject.build(at: projectURL, finalize: false)
        let original = try ProjectPackage.load(at: projectURL).manifest

        let journal = try JournalWriter(resumingAt: built.layout.journalURL)
        try await journal.append(type: .pause, timeNs: 5_000_000_000, payload: JournalPayload.empty())
        try await journal.append(type: .resume, timeNs: 9_000_000_000, payload: JournalPayload.empty())
        try await journal.append(
            type: .discontinuity, timeNs: 9_000_000_000,
            payload: JournalPayload.discontinuity(
                trackID: nil, startNs: 5_000_000_000, endNs: 9_000_000_000, reason: "pause"))
        // Crash during manifest replacement: the main manifest is torn.
        try Data("torn json".utf8).write(to: built.layout.manifestURL)

        let recoveredURL = directory.appendingPathComponent("recovered-identity.aks")
        _ = try await Recovery.recover(
            projectAt: projectURL, options: RecoveryOptions(destination: recoveredURL))
        let recovered = try ProjectPackage.load(at: recoveredURL)
        XCTAssertEqual(recovered.manifest.projectID, original.projectID)
        XCTAssertEqual(recovered.manifest.clock, original.clock)
        XCTAssertNotEqual(recovered.manifest.modifiedAt, recovered.manifest.createdAt)
        XCTAssertEqual(recovered.journal.records(ofType: .pause).count, 1)
        XCTAssertEqual(recovered.journal.records(ofType: .resume).count, 1)
        XCTAssertEqual(recovered.journal.records(ofType: .discontinuity).count, 1)
    }

    func testExtractorReportsMissingCommittedChunk() async throws {
        let built = try await TestProject.build(at: projectURL)
        try FileManager.default.removeItem(
            at: built.layout.eventsDirectory.appendingPathComponent("cursor-000001.jsonl"))
        let destination = directory.appendingPathComponent("extract-missing")
        let report = try await Extractor.extract(projectAt: projectURL, to: destination)
        XCTAssertTrue(report.issues.contains {
            $0.code == "asset.missing" && ($0.path?.contains("cursor-000001") ?? false)
        }, "\(report.issues)")
    }

    func testExtractorWorksWithDestroyedMetadata() async throws {
        let built = try await TestProject.build(at: projectURL)
        // Destroy both manifest and journal.
        try Data("corrupt".utf8).write(to: built.layout.manifestURL)
        try Data("corrupt".utf8).write(to: built.layout.journalURL)

        let destination = directory.appendingPathComponent("extracted")
        let report = try await Extractor.extract(projectAt: projectURL, to: destination)
        XCTAssertEqual(report.mediaFiles.count, 4)
        XCTAssertTrue(report.eventExports.contains("events.json"))
        XCTAssertTrue(report.eventExports.contains("events.csv"))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: destination.appendingPathComponent("raw/screen/display-1-000001.mov").path))
        let csv = try String(
            contentsOf: destination.appendingPathComponent("events.csv"), encoding: .utf8)
        XCTAssertEqual(csv.split(separator: "\n").count, 4)  // header + 3 records
    }
}
