import Foundation
import ProjectModel
import Synchronization
import XCTest

@testable import CaptureCore

/// Device sample-rate honesty:
/// a microphone whose callback cadence belongs to a different rate than it
/// declares (the classic AirPods 44.1/48 k lie) is detected from delivered
/// frames vs pts span, journaled once, and committed descriptors are stamped
/// with the observed standard rate. Sub-lie deviations surface as one
/// measured clock-drift fault. Raw CAF bytes are untouched in every case.
final class AudioRateLieTests: XCTestCase {
    private var directory: URL!
    private var layout: ProjectLayout!

    override func setUp() {
        super.setUp()
        AtomicFile.fullFsync = false
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("screenreel-ratelie-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        layout = ProjectLayout(root: directory.appendingPathComponent("writer.screenreel"))
        for dir in layout.initialDirectories {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        AtomicFile.fullFsync = true
        super.tearDown()
    }

    // MARK: - Lying source

    /// Synthetic microphone that declares one sample rate while its pts
    /// cadence follows another: each 1024-frame chunk is timestamped from
    /// `actualRate`, exactly how a misreporting device presents.
    private final class LyingAudioSource: AudioChunkSource, @unchecked Sendable {
        private let declaredRate: Double
        private let actualRate: Double
        private let durationNs: Int64
        private let pace: Double
        private let chunkFrames = 1024

        private let stopped = Mutex(false)
        private var task: Task<Void, Never>?

        init(declaredRate: Double = 48_000, actualRate: Double, durationNs: Int64, pace: Double) {
            self.declaredRate = declaredRate
            self.actualRate = actualRate
            self.durationNs = durationNs
            self.pace = pace
        }

        func start(_ handler: @escaping @Sendable (AudioChunk) -> Void) async throws {
            let declaredRate = self.declaredRate
            let actualRate = self.actualRate
            let durationNs = self.durationNs
            let pace = self.pace
            let chunkFrames = self.chunkFrames
            task = Task.detached(priority: .userInitiated) { [weak self] in
                var frame = 0
                let wallStart = DispatchTime.now().uptimeNanoseconds
                while true {
                    if Task.isCancelled { return }
                    if let self, self.isStopped() { return }
                    let ptsNs = Int64(Double(frame) / actualRate * 1_000_000_000)
                    if ptsNs >= durationNs { return }
                    let samples = [Float](repeating: 0.2, count: chunkFrames)
                    handler(AudioChunk(
                        samples: samples, frameCount: chunkFrames, channels: 1,
                        sampleRate: declaredRate, ptsNs: ptsNs))
                    frame += chunkFrames
                    if pace > 0 {
                        let targetWall = wallStart
                            + UInt64(Double(frame) / actualRate * 1_000_000_000 / pace)
                        let now = DispatchTime.now().uptimeNanoseconds
                        if targetWall > now {
                            try? await Task.sleep(nanoseconds: targetWall - now)
                        }
                    }
                }
            }
        }

        func stop() async {
            stopped.withLock { $0 = true }
            task?.cancel()
            await task?.value
        }

        func waitUntilFinished() async {
            await task?.value
        }

        private func isStopped() -> Bool {
            stopped.withLock { $0 }
        }
    }

    // MARK: - Direct-writer plumbing

    private final class FaultRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [(kind: String, message: String)] = []

        func append(kind: String, message: String) {
            lock.lock()
            entries.append((kind, message))
            lock.unlock()
        }

        func all() -> [(kind: String, message: String)] {
            lock.lock()
            defer { lock.unlock() }
            return entries
        }
    }

    private func makeWriter(
        collector: CommitCollector, faults: FaultRecorder
    ) -> AudioSegmentWriter {
        AudioSegmentWriter(
            trackID: UUID(),
            trackType: .microphone,
            layout: layout,
            sampleRate: 48_000,
            channels: 1,
            segmentDurationNs: 4_000_000_000,
            onOpen: { path, sequence in
                await collector.noteOpen(path: path, sequence: sequence)
            },
            onCommit: { descriptor in
                await collector.noteCommit(descriptor)
            },
            onFault: { kind, message in
                faults.append(kind: kind, message: message)
            })
    }

    /// Feed contiguous 1024-frame chunks whose pts cadence follows
    /// `actualRate` until the pts span reaches `spanNs`.
    private func feed(
        _ writer: AudioSegmentWriter, actualRate: Double, spanNs: Int64
    ) async throws {
        var frame = 0
        while true {
            let ptsNs = Int64(Double(frame) / actualRate * 1_000_000_000)
            if ptsNs >= spanNs { break }
            try await writer.append(AudioChunk(
                samples: [Float](repeating: 0.2, count: 1024),
                frameCount: 1024, channels: 1, sampleRate: 48_000, ptsNs: ptsNs))
            frame += 1024
        }
        try await writer.finish()
    }

    /// First integer in a fault message (the drift message leads with ppm).
    private func firstInteger(in message: String) -> Int? {
        message.components(separatedBy: " ").lazy.compactMap { Int($0) }.first
    }

    // MARK: - Tests

    /// A device declared 48 k delivering a 24 k cadence through a REAL
    /// session: detected within ~2 s of audio, exactly one journaled
    /// `audio.rateMismatch` fault naming declared vs observed, and
    /// descriptors committed after detection carry the observed 24 000 Hz.
    func testHalfRateCadenceIsDetectedJournaledOnceAndStamped() async throws {
        let projectURL = directory.appendingPathComponent("lie.screenreel")
        let configuration = CaptureConfiguration(
            widthPx: 320, heightPx: 180, nominalFrameRate: 30,
            videoCodec: .hevc, displayID: 1,
            microphoneEnabled: true, microphoneDeviceName: "Lying Microphone",
            segmentDurationSeconds: 4)
        let warnings = Mutex<[String]>([])
        let session = CaptureSession(
            projectURL: projectURL,
            configuration: configuration,
            callbacks: .init(onWarning: { kind, _ in
                warnings.withLock { $0.append(kind) }
            }))
        let durationNs: Int64 = 6_000_000_000
        let screen = SyntheticScreenSource(
            width: 320, height: 180, frameRate: 30, durationNs: durationNs, pace: 2)
        let mic = LyingAudioSource(actualRate: 24_000, durationNs: durationNs, pace: 2)
        try await session.start(screen: screen, microphone: mic, systemAudio: nil)
        await screen.waitUntilFinished()
        await mic.waitUntilFinished()
        _ = try await session.stop()

        let loaded = try ProjectPackage.load(at: projectURL)
        let faults = loaded.journal.records(ofType: .fault).filter {
            $0.payload["kind"]?.stringValue == "audio.rateMismatch"
        }
        XCTAssertEqual(faults.count, 1)
        let message = faults.first?.payload["message"]?.stringValue ?? ""
        XCTAssertTrue(message.contains("48000"), message)
        XCTAssertTrue(message.contains("24000"), message)
        XCTAssertTrue(warnings.withLock { $0 }.contains("audio.rateMismatch"))

        // Descriptors committed after the ~2 s detection point are truthful.
        let micSegments = (loaded.manifest.tracks.first { $0.type == .microphone }?.segments ?? [])
            .sorted { $0.sequenceInTrack < $1.sequenceInTrack }
        XCTAssertFalse(micSegments.isEmpty)
        XCTAssertEqual(micSegments.last?.audio?.sampleRate, 24_000)
        let stamped = micSegments.filter { $0.audio?.sampleRate == 24_000 }
        XCTAssertFalse(stamped.isEmpty)
        // Detection latches within ~2 s of delivered audio (with generous
        // slack for a mid-window restart): every segment starting in the
        // back quarter of the recording carries the observed rate.
        for segment in micSegments where segment.normalizedStartNs > 4_500_000_000 {
            XCTAssertEqual(segment.audio?.sampleRate, 24_000, "\(segment.sequenceInTrack)")
        }
    }

    /// A well-behaved 48 k stream over a long track: descriptors keep the
    /// declared rate and neither the lie nor the drift fault ever fires.
    func testWellBehavedStreamKeepsDeclaredRateAndFaultsNothing() async throws {
        let collector = CommitCollector()
        let faults = FaultRecorder()
        let writer = makeWriter(collector: collector, faults: faults)
        try await feed(writer, actualRate: 48_000, spanNs: 66_000_000_000)

        XCTAssertTrue(faults.all().isEmpty, "\(faults.all())")
        let committed = await collector.committed
        XCTAssertFalse(committed.isEmpty)
        for descriptor in committed {
            XCTAssertEqual(descriptor.audio?.sampleRate, 48_000)
            XCTAssertNil(descriptor.discontinuityBefore)
        }
    }

    /// A device clock running 47.8 k against a declared 48 k — a 0.42 %
    /// (≈4 200 ppm) lie too small for the rate gate — accumulates real
    /// desync and journals exactly one measured clock-drift fault once it
    /// passes 250 ms.
    func testSlowDeviceClockJournalsOneDriftFaultWithMeasuredPpm() async throws {
        let collector = CommitCollector()
        let faults = FaultRecorder()
        let writer = makeWriter(collector: collector, faults: faults)
        try await feed(writer, actualRate: 47_800, spanNs: 66_000_000_000)

        let drift = faults.all().filter { $0.kind == "audio.clockDrift" }
        XCTAssertEqual(drift.count, 1, "\(faults.all())")
        XCTAssertTrue(faults.all().allSatisfy { $0.kind == "audio.clockDrift" }, "\(faults.all())")
        let message = drift.first?.message ?? ""
        XCTAssertTrue(message.contains("ppm"), message)
        let ppm = try XCTUnwrap(firstInteger(in: message), message)
        // (48000 − 47800) / 48000 ≈ 4 167 ppm.
        XCTAssertGreaterThan(ppm, 3_500, message)
        XCTAssertLessThan(ppm, 4_800, message)

        // Sub-tolerance drift must not roll segments spuriously or stamp a
        // different rate — 47.8 k rounds back to the declared standard.
        let committed = await collector.committed
        for descriptor in committed {
            XCTAssertEqual(descriptor.audio?.sampleRate, 48_000)
            XCTAssertNil(descriptor.discontinuityBefore)
        }
    }
}
