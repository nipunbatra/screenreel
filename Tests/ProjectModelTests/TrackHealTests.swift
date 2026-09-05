import XCTest

@testable import ProjectModel

/// Fixture for cross-track time-scale tests: a finalized project whose
/// journal wall clock reports the TRUE session duration while one track's
/// descriptors may claim a stretched (scaled) amount of source time — the
/// double-rate-timestamp bug class.
enum HealFixture {
    struct Built {
        var url: URL
        var layout: ProjectLayout
        var screenTrackID: UUID
        var micTrackID: UUID?
        /// True wall-clock duration the retimed journal reports.
        var wallSpanNs: Int64
    }

    /// Build with per-track time scales. Scale `1` is a truthful track;
    /// `2` claims twice the source time the wall clock saw. `micScale: nil`
    /// registers no mic track at all (the single-track case), and
    /// `micSegments` shortens the mic truthfully (late stop, not a stretch).
    static func build(
        at url: URL,
        segments: Int = 2,
        micSegments: Int? = nil,
        segmentSpanNs: Int64 = 4_000_000_000,
        screenScale: Int64 = 1,
        micScale: Int64? = 1
    ) async throws -> Built {
        let clock = ClockAnchor(
            originContinuousTicks: 100, originAbsoluteTicks: 100,
            timebaseNumer: 125, timebaseDenom: 3, originWallTime: RFC3339.now())
        let created = try await ProjectPackage.create(at: url, clock: clock)
        let layout = created.layout
        let journal = created.journal
        let store = created.manifestStore

        let screenTrack = TrackDescriptor(type: .screen, displayID: 1, cursorBaked: false)
        var tracks: [(track: TrackDescriptor, type: TrackType, scale: Int64, count: Int)] = [
            (screenTrack, .screen, screenScale, segments)
        ]
        var micTrack: TrackDescriptor?
        if let micScale {
            let track = TrackDescriptor(type: .microphone, deviceName: "Fake Mic")
            micTrack = track
            tracks.append((track, .microphone, micScale, micSegments ?? segments))
        }
        for entry in tracks {
            try await journal.append(
                type: .trackStarted, timeNs: 0,
                payload: JournalPayload.trackStarted(entry.track))
            _ = try await store.save { $0.tracks.append(entry.track) }
        }

        for entry in tracks {
            for index in 0..<entry.count {
                let name = ProjectLayout.segmentFileName(
                    type: entry.type, displayID: entry.track.displayID, sequence: index + 1)
                let fileURL = layout.mediaDirectory(for: entry.type)
                    .appendingPathComponent(name)
                let contents = Data("fake-\(entry.type.rawValue)-\(index + 1)".utf8)
                try contents.write(to: fileURL)
                let startNs = Int64(index) * segmentSpanNs * entry.scale
                let endNs = Int64(index + 1) * segmentSpanNs * entry.scale
                var descriptor = SegmentDescriptor(
                    trackID: entry.track.id, trackType: entry.type,
                    path: layout.relativePath(of: fileURL),
                    sequenceInTrack: index + 1,
                    container: entry.type == .screen ? .mov : .caf,
                    codec: entry.type == .screen ? .hevc : .pcmFloat32,
                    audio: entry.type == .microphone
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
        }

        try await journal.append(
            type: .sessionStopped, timeNs: 0, payload: JournalPayload.empty())
        try await journal.append(
            type: .validationCompleted, timeNs: 0, payload: JournalPayload.empty())
        try await journal.append(
            type: .sessionFinalized, timeNs: 0, payload: JournalPayload.empty())
        _ = try await store.save { $0.state = .ready }
        try? FileManager.default.removeItem(at: layout.sessionLockURL)

        // The wall clock never lies with the device: rewrite journal wall
        // times so the span sessionCreated → last commit equals the TRUE
        // session duration regardless of any stretched descriptor times.
        let wallSpanNs = Int64(segments) * segmentSpanNs
        try retimeJournal(at: layout.journalURL, wallSpanNs: wallSpanNs)

        return Built(
            url: url, layout: layout,
            screenTrackID: screenTrack.id, micTrackID: micTrack?.id,
            wallSpanNs: wallSpanNs)
    }

    /// Rewrite every record's wallTime (sessionCreated at T0, everything
    /// after at T0 + span) and recompute the hash chain so the journal stays
    /// fully verified. Fixture construction only.
    private static func retimeJournal(at url: URL, wallSpanNs: Int64) throws {
        let scan = try JournalReader.scan(url: url)
        precondition(scan.truncationReason == nil, "fixture journal must be intact")
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let end = start.addingTimeInterval(Double(wallSpanNs) / 1e9)
        var previousHash = journalGenesisHash
        var lines: [String] = []
        for var record in scan.records {
            record.wallTime = RFC3339.string(from: record.type == .sessionCreated ? start : end)
            record.prevHash = previousHash
            record.hash = try record.computedHash()
            previousHash = record.hash
            lines.append(try record.jsonlLine())
        }
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: url)
    }
}

/// Cross-track duration sanity + heal: detection
/// needs BOTH references to deviate; repair needs BOTH references to agree;
/// absurd ratios and single-track projects are never healed; healthy and
/// merely-short tracks are never touched.
final class TrackHealTests: XCTestCase {
    private var directory: URL!

    override func setUp() {
        super.setUp()
        AtomicFile.fullFsync = false
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("screenreel-heal-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        AtomicFile.fullFsync = true
        super.tearDown()
    }

    private var projectURL: URL { directory.appendingPathComponent("p.screenreel") }

    private func micSegments(in manifest: Manifest) throws -> [SegmentDescriptor] {
        let track = try XCTUnwrap(manifest.tracks.first { $0.type == .microphone })
        return (track.segments ?? []).sorted { $0.sequenceInTrack < $1.sequenceInTrack }
    }

    func testStretchedTrackIsDetectedHealedAndRevalidatesCleanly() async throws {
        let built = try await HealFixture.build(at: projectURL, micScale: 2)
        let micID = try XCTUnwrap(built.micTrackID)

        // Detection: warning with the measured ratio, on the right track.
        let report = await Validator().validate(projectAt: projectURL)
        let anomalies = report.issues.filter { $0.code == "track.timeScaleAnomaly" }
        XCTAssertEqual(anomalies.count, 1, "\(report.issues)")
        XCTAssertEqual(anomalies.first?.severity, .warning)
        XCTAssertEqual(anomalies.first?.path, micID.uuidString)
        XCTAssertTrue(anomalies.first?.message.contains("2.00×") ?? false, "\(anomalies)")

        let originalJournal = try Data(contentsOf: built.layout.journalURL)
        let originalManifest = try Data(contentsOf: built.layout.manifestURL)
        let micFile = built.layout.microphoneDirectory.appendingPathComponent("mic-000001.caf")
        let originalMicBytes = try Data(contentsOf: micFile)

        // Heal: siblings AND journal wall span agree → time mapping rewritten
        // in the recovered copy by the measured factor.
        let recoveredURL = directory.appendingPathComponent("recovered.screenreel")
        let recovery = try await Recovery.recover(
            projectAt: projectURL, options: RecoveryOptions(destination: recoveredURL))
        XCTAssertEqual(recovery.healedTracks, [micID.uuidString])
        XCTAssertTrue(recovery.issues.contains { $0.code == "track.timeScaleHealed" })

        let recovered = try ProjectPackage.load(at: recoveredURL)
        let healed = try micSegments(in: recovered.manifest)
        XCTAssertEqual(healed.map(\.normalizedStartNs), [0, 4_000_000_000])
        XCTAssertEqual(healed.map(\.normalizedEndNs), [4_000_000_000, 8_000_000_000])
        XCTAssertEqual(healed.map(\.sourceStartNs), [0, 4_000_000_000])
        XCTAssertEqual(healed.map(\.sourceEndNs), [4_000_000_000, 8_000_000_000])
        XCTAssertEqual(healed.map(\.timingEstimated), [true, true])
        XCTAssertEqual(recovered.manifest.durationNs, 8_000_000_000)
        // Screen (the truthful sibling) is untouched.
        let screen = try XCTUnwrap(recovered.manifest.tracks.first { $0.type == .screen })
        XCTAssertEqual(
            (screen.segments ?? []).map(\.normalizedEndNs), [4_000_000_000, 8_000_000_000])
        XCTAssertEqual((screen.segments ?? []).compactMap(\.timingEstimated), [])

        // The heal is documented in the recovered journal.
        let heals = recovered.journal.records(ofType: .fault).filter {
            $0.payload["kind"]?.stringValue == "track.timeScaleHealed"
        }
        XCTAssertEqual(heals.count, 1)
        XCTAssertTrue(
            heals.first?.payload["message"]?.stringValue?.contains(micID.uuidString) ?? false)

        // The recovered copy re-validates cleanly: no anomaly, no errors.
        let revalidated = await Validator().validate(projectAt: recoveredURL)
        XCTAssertTrue(revalidated.isHealthy, "\(revalidated.issues)")
        XCTAssertFalse(revalidated.issues.contains { $0.code == "track.timeScaleAnomaly" })

        // The original is untouched: metadata bytes and raw media identical.
        XCTAssertEqual(try Data(contentsOf: built.layout.journalURL), originalJournal)
        XCTAssertEqual(try Data(contentsOf: built.layout.manifestURL), originalManifest)
        XCTAssertEqual(try Data(contentsOf: micFile), originalMicBytes)
    }

    func testHealthyProjectIsNeverTouchedAndNeverFlagged() async throws {
        let built = try await HealFixture.build(at: projectURL, micScale: 1)

        let report = await Validator().validate(projectAt: projectURL)
        XCTAssertTrue(report.isHealthy, "\(report.issues)")
        XCTAssertFalse(report.issues.contains { $0.code == "track.timeScaleAnomaly" })

        let originalManifest = try Data(contentsOf: built.layout.manifestURL)
        let recoveredURL = directory.appendingPathComponent("recovered.screenreel")
        let recovery = try await Recovery.recover(
            projectAt: projectURL, options: RecoveryOptions(destination: recoveredURL))
        XCTAssertEqual(recovery.healedTracks, [])
        XCTAssertFalse(recovery.issues.contains { $0.code.hasPrefix("track.timeScale") })

        // Original manifest byte-identical; recovered descriptors carry the
        // exact original time mapping, not a rescaled one.
        XCTAssertEqual(try Data(contentsOf: built.layout.manifestURL), originalManifest)
        let recovered = try ProjectPackage.load(at: recoveredURL)
        let mic = try micSegments(in: recovered.manifest)
        XCTAssertEqual(mic.map(\.normalizedEndNs), [4_000_000_000, 8_000_000_000])
        XCTAssertEqual(mic.compactMap(\.timingEstimated), [])
        XCTAssertTrue(recovered.journal.records(ofType: .fault).isEmpty)
    }

    func testAbsurdRatioIsFlaggedButNeverHealed() async throws {
        let built = try await HealFixture.build(at: projectURL, micScale: 10)
        let micID = try XCTUnwrap(built.micTrackID)

        // Flagged by the validator, with the refusal spelled out.
        let report = await Validator().validate(projectAt: projectURL)
        let anomaly = try XCTUnwrap(
            report.issues.first { $0.code == "track.timeScaleAnomaly" })
        XCTAssertEqual(anomaly.path, micID.uuidString)
        XCTAssertTrue(anomaly.message.contains("10.00×"), anomaly.message)
        XCTAssertTrue(anomaly.message.contains("refused"), anomaly.message)

        // Recovery flags it too and preserves the descriptors verbatim.
        let recoveredURL = directory.appendingPathComponent("recovered.screenreel")
        let recovery = try await Recovery.recover(
            projectAt: projectURL, options: RecoveryOptions(destination: recoveredURL))
        XCTAssertEqual(recovery.healedTracks, [])
        XCTAssertTrue(recovery.issues.contains { $0.code == "track.timeScaleAnomaly" })
        XCTAssertFalse(recovery.issues.contains { $0.code == "track.timeScaleHealed" })

        let recovered = try ProjectPackage.load(at: recoveredURL)
        let mic = try micSegments(in: recovered.manifest)
        XCTAssertEqual(mic.map(\.normalizedEndNs), [40_000_000_000, 80_000_000_000])
        XCTAssertEqual(mic.compactMap(\.timingEstimated), [])
        XCTAssertTrue(recovered.journal.records(ofType: .fault).isEmpty)
    }

    func testSingleTrackProjectIsNeverHealed() async throws {
        // One media track, stretched 2× vs the wall clock: with no sibling
        // there is only one reference, and one reference never justifies
        // rewriting a time mapping.
        _ = try await HealFixture.build(at: projectURL, screenScale: 2, micScale: nil)

        let report = await Validator().validate(projectAt: projectURL)
        XCTAssertFalse(report.issues.contains { $0.code == "track.timeScaleAnomaly" })

        let recoveredURL = directory.appendingPathComponent("recovered.screenreel")
        let recovery = try await Recovery.recover(
            projectAt: projectURL, options: RecoveryOptions(destination: recoveredURL))
        XCTAssertEqual(recovery.healedTracks, [])

        let recovered = try ProjectPackage.load(at: recoveredURL)
        let screen = try XCTUnwrap(recovered.manifest.tracks.first { $0.type == .screen })
        XCTAssertEqual(
            (screen.segments ?? []).map(\.normalizedEndNs), [8_000_000_000, 16_000_000_000])
        XCTAssertEqual((screen.segments ?? []).compactMap(\.timingEstimated), [])
    }

    /// A short mic (late start, early stop) is legal capture history: the
    /// comparison is one-sided, so the short track is never flagged — and
    /// the truthful screen track is protected by the wall reference.
    func testMerelyShortTrackIsLeftAlone() async throws {
        _ = try await HealFixture.build(at: projectURL, micSegments: 1, micScale: 1)

        let report = await Validator().validate(projectAt: projectURL)
        XCTAssertFalse(
            report.issues.contains { $0.code == "track.timeScaleAnomaly" },
            "\(report.issues)")

        let recoveredURL = directory.appendingPathComponent("recovered.screenreel")
        let recovery = try await Recovery.recover(
            projectAt: projectURL, options: RecoveryOptions(destination: recoveredURL))
        XCTAssertEqual(recovery.healedTracks, [])
        // The short mic keeps its truthful single segment.
        let recovered = try ProjectPackage.load(at: recoveredURL)
        let mic = try micSegments(in: recovered.manifest)
        XCTAssertEqual(mic.map(\.normalizedEndNs), [4_000_000_000])
    }
}
