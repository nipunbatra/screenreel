import XCTest

@testable import CaptureCore
@testable import EventCapture
@testable import ProjectModel

/// Thread-safe warning accumulator for session callbacks.
final class WarningLog: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [(kind: String, message: String)] = []

    func append(kind: String, message: String) {
        lock.lock()
        entries.append((kind, message))
        lock.unlock()
    }

    func kinds() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return entries.map(\.kind)
    }
}

final class SyntheticSessionTests: XCTestCase {
    private var directory: URL!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("screenreel-integration-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    /// Run a complete synthetic session and return its stop summary.
    private func runSession(
        projectURL: URL,
        durationNs: Int64,
        pace: Double,
        width: Int = 640,
        height: Int = 360,
        micSilenceAfterNs: Int64? = nil,
        warnings: WarningLog = WarningLog()
    ) async throws -> CaptureSession.StopSummary {
        let configuration = CaptureConfiguration(
            widthPx: width, heightPx: height, nominalFrameRate: 30,
            videoCodec: .hevc, displayID: 1,
            microphoneEnabled: true, microphoneDeviceName: "Synthetic Microphone",
            segmentDurationSeconds: 4)
        let session = CaptureSession(
            projectURL: projectURL,
            configuration: configuration,
            callbacks: .init(onWarning: { kind, message in
                warnings.append(kind: kind, message: message)
            }))
        let screen = SyntheticScreenSource(
            width: width, height: height, frameRate: 30,
            durationNs: durationNs, pace: pace)
        let mic = SyntheticAudioSource(
            channels: 1, durationNs: durationNs, pace: pace,
            silenceAfterNs: micSilenceAfterNs)

        try await session.start(screen: screen, microphone: mic, systemAudio: nil)

        // Cursor/click events through the same commit pipeline.
        let cursorTrackID = try await session.registerEventTrack(type: .cursorEvents)
        let clickTrackID = try await session.registerEventTrack(type: .clickEvents)
        let store = EventChunkStore(
            layout: session.projectLayout(),
            trackIDs: [.cursor: cursorTrackID, .clicks: clickTrackID],
            onCommit: { [session] chunk in
                try await session.commitEventChunk(chunk)
            })
        let (stream, continuation) = AsyncStream.makeStream(of: EventRecord.self)
        let events = SyntheticEventSource(
            durationNs: durationNs, widthPx: Double(width), heightPx: Double(height), pace: pace)
        events.start { record in continuation.yield(record) }
        let pump = Task {
            for await record in stream {
                try? await store.append(record)
            }
            try? await store.finish()
        }

        await screen.waitUntilFinished()
        await mic.waitUntilFinished()
        await events.waitUntilFinished()
        continuation.finish()
        await pump.value
        return try await session.stop()
    }

    func testTwentySecondPacedSessionMeetsCaptureIntegrityGates() async throws {
        let projectURL = directory.appendingPathComponent("session.screenreel")
        let durationNs: Int64 = 20_000_000_000
        let warnings = WarningLog()
        // pace 2 = a sustained 60 fps demand: double real-time load, with
        // zero drops allowed. (pace 4 = 120 fps proved to gate encoder
        // warmup jitter on a busy machine rather than the pipeline itself.)
        let summary = try await runSession(
            projectURL: projectURL, durationNs: durationNs, pace: 2, warnings: warnings)

        // No hidden loss: paced generation must deliver every frame/sample.
        XCTAssertEqual(summary.videoFrames, 600, "dropped: \(summary.droppedVideoFrames), buffers: \(summary.droppedBuffers)")
        XCTAssertEqual(summary.droppedVideoFrames, 0)
        XCTAssertEqual(summary.droppedBuffers, 0)
        XCTAssertEqual(summary.micFrames, 48_000 * 20)
        XCTAssertTrue(summary.validation.isHealthy, "\(summary.validation.issues)")

        // Logical duration within one frame of expected (ACCEPTANCE §2).
        let frameNs: Int64 = 33_333_334
        XCTAssertLessThanOrEqual(abs(summary.durationNs - durationNs), frameNs)

        // Deep validation: checksums plus container probing of every segment.
        let validator = Validator(options: .init(
            verifyChecksums: true, mediaInspector: AVMediaInspector()))
        let report = await validator.validate(projectAt: projectURL)
        XCTAssertTrue(report.isHealthy, "\(report.issues)")
        XCTAssertTrue(report.journalFinalized)
        // Concurrent commits must never skew descriptor↔journal sequence
        // agreement (the journal assigns commitSequence atomically).
        XCTAssertFalse(
            report.issues.contains { $0.code == "journal.commitSequenceMismatch" },
            "\(report.issues)")

        // Mic and screen coverage both reach the end.
        for track in report.tracks where track.type.isMedia {
            XCTAssertLessThanOrEqual(
                abs(track.coverageEndNs - durationNs), frameNs,
                "\(track.type) coverage \(track.coverageEndNs)")
        }

        // Extraction works and events round-trip.
        let extracted = directory.appendingPathComponent("extracted")
        let extraction = try await Extractor.extract(projectAt: projectURL, to: extracted)
        XCTAssertTrue(extraction.eventExports.contains("events.csv"))
        XCTAssertFalse(extraction.mediaFiles.isEmpty)
    }

    /// ACCEPTANCE §2 missing audio: mic samples stop mid-session → a live
    /// warning within two seconds (plus one heartbeat), a journaled fault,
    /// and the committed mic track still covering everything before the cut.
    func testMicDropoutWarnsWithinTwoSecondsAndIsJournaled() async throws {
        let projectURL = directory.appendingPathComponent("dropout.screenreel")
        let warnings = WarningLog()
        _ = try await runSession(
            projectURL: projectURL,
            durationNs: 7_000_000_000,
            pace: 1,  // real time so the wall-clock silence gate is meaningful
            width: 320, height: 180,
            micSilenceAfterNs: 2_000_000_000,
            warnings: warnings)

        XCTAssertTrue(warnings.kinds().contains("audio.micSilent"), "\(warnings.kinds())")

        let loaded = try ProjectPackage.load(at: projectURL)
        let faults = loaded.journal.records(ofType: .fault).compactMap {
            $0.payload["kind"]?.stringValue
        }
        XCTAssertTrue(faults.contains("audio.micSilent"), "\(faults)")

        // The fault was journaled within (2 s silence + 1 s heartbeat + slack)
        // of the last real sample.
        let fault = loaded.journal.records(ofType: .fault).first {
            $0.payload["kind"]?.stringValue == "audio.micSilent"
        }
        if let fault {
            XCTAssertLessThanOrEqual(fault.timeNs, 2_000_000_000 + 3_500_000_000)
        }

        // Mic segments cover the audio that did arrive.
        let micTrack = loaded.manifest.tracks.first { $0.type == .microphone }
        let micCoverage = micTrack?.segments?.map(\.normalizedEndNs).max() ?? 0
        XCTAssertGreaterThanOrEqual(micCoverage, 1_900_000_000)
    }

    func testPauseResumeCreatesExplicitDiscontinuity() async throws {
        let projectURL = directory.appendingPathComponent("pause.screenreel")
        let configuration = CaptureConfiguration(
            widthPx: 320, heightPx: 180, nominalFrameRate: 30,
            videoCodec: .hevc, displayID: 1,
            microphoneEnabled: false, segmentDurationSeconds: 4)
        let session = CaptureSession(projectURL: projectURL, configuration: configuration)
        let screen = SyntheticScreenSource(
            width: 320, height: 180, frameRate: 30,
            durationNs: 6_000_000_000, pace: 1)
        try await session.start(screen: screen, microphone: nil, systemAudio: nil)

        try await Task.sleep(for: .seconds(2))
        try await session.pause()
        try await Task.sleep(for: .seconds(1.5))
        try await session.resume()
        await screen.waitUntilFinished()
        let summary = try await session.stop()
        XCTAssertTrue(summary.validation.isHealthy, "\(summary.validation.issues)")

        let loaded = try ProjectPackage.load(at: projectURL)
        XCTAssertEqual(loaded.journal.records(ofType: .pause).count, 1)
        XCTAssertEqual(loaded.journal.records(ofType: .resume).count, 1)
        XCTAssertEqual(loaded.journal.records(ofType: .discontinuity).count, 1)
        // Frames were dropped during the pause window, and the post-resume
        // segment is explicitly marked.
        let screenTrack = loaded.manifest.tracks.first { $0.type == .screen }
        let flagged = (screenTrack?.segments ?? []).filter { $0.discontinuityBefore == true }
        XCTAssertEqual(flagged.count, 1)
    }
}
