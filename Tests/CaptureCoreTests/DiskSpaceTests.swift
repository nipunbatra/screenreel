import Foundation
import ProjectModel
import XCTest

@testable import CaptureCore

/// Low-disk behavior: a session on an exhausting
/// volume must stop ITSELF cleanly — every open segment committed, manifest
/// finalized, project loadable — never die on a failed media write. The
/// soft threshold warns exactly once; the probe resolves not-yet-created
/// paths to their destination volume.
final class DiskSpaceTests: XCTestCase {
    private var directory: URL!

    override func setUp() {
        super.setUp()
        AtomicFile.fullFsync = false
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("aks-disk-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        AtomicFile.fullFsync = true
        super.tearDown()
    }

    /// Deterministic provider: serves `sequence` one value per probe, then
    /// `fallback` forever — the heartbeat cadence does the timing.
    private final class FakeFreeSpaceProvider: FreeSpaceProviding, @unchecked Sendable {
        private let lock = NSLock()
        private var sequence: [Int64]
        private let fallback: Int64
        private(set) var probes = 0

        init(sequence: [Int64], then fallback: Int64) {
            self.sequence = sequence
            self.fallback = fallback
        }

        func freeBytes(for url: URL) -> Int64? {
            lock.lock()
            defer { lock.unlock() }
            probes += 1
            return sequence.isEmpty ? fallback : sequence.removeFirst()
        }
    }

    private final class WarningRecorder: @unchecked Sendable {
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

    private func makeSession(
        projectURL: URL, provider: FakeFreeSpaceProvider, warnings: WarningRecorder
    ) -> CaptureSession {
        let configuration = CaptureConfiguration(
            widthPx: 320, heightPx: 180, nominalFrameRate: 30,
            videoCodec: .hevc, displayID: 1,
            microphoneEnabled: true, microphoneDeviceName: "Synthetic Microphone",
            segmentDurationSeconds: 4)
        return CaptureSession(
            projectURL: projectURL,
            configuration: configuration,
            callbacks: .init(onWarning: { kind, message in
                warnings.append(kind: kind, message: message)
            }),
            freeSpace: provider)
    }

    /// (a) Free space drains below the hard threshold mid-session → the
    /// session self-stops CLEANLY: segments committed, no partials, manifest
    /// finalized, project loads, validation healthy or recoverable, and the
    /// operator saw the warning.
    func testExhaustedDiskStopsSessionCleanly() async throws {
        let projectURL = directory.appendingPathComponent("full.aks")
        let warnings = WarningRecorder()
        // First heartbeat sees plenty; every later probe is below 50 MB.
        let provider = FakeFreeSpaceProvider(sequence: [10_000_000_000], then: 30_000_000)
        let session = makeSession(projectURL: projectURL, provider: provider, warnings: warnings)

        // Sources far outlast the test: only the self-stop ends them.
        let screen = SyntheticScreenSource(
            width: 320, height: 180, frameRate: 30,
            durationNs: 30_000_000_000, pace: 1)
        let mic = SyntheticAudioSource(
            channels: 1, durationNs: 30_000_000_000, pace: 1)
        try await session.start(screen: screen, microphone: mic, systemAudio: nil)

        // Heartbeats run at 1 Hz: exhaustion is noticed on the second beat.
        var selfStopped = false
        for _ in 0..<240 {
            if await session.finishedStopSummary() != nil {
                selfStopped = true
                break
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertTrue(selfStopped, "session never self-stopped on a full disk")
        XCTAssertGreaterThanOrEqual(provider.probes, 2)
        XCTAssertTrue(warnings.kinds().contains("disk.full"), "\(warnings.kinds())")

        // A finished stop is safely repeatable for the operator's own stop.
        let summary = try await session.stop()
        XCTAssertGreaterThan(summary.videoFrames, 0)
        XCTAssertGreaterThan(summary.micFrames, 0)

        // Everything captured before exhaustion is committed and readable.
        let loaded = try ProjectPackage.load(at: projectURL)
        XCTAssertTrue(
            loaded.manifest.state == .ready || loaded.manifest.state == .recoverable,
            "state \(loaded.manifest.state)")
        let faults = loaded.journal.records(ofType: .fault).compactMap {
            $0.payload["kind"]?.stringValue
        }
        XCTAssertEqual(faults.filter { $0 == "disk.full" }.count, 1, "\(faults)")
        for type in [TrackType.screen, .microphone] {
            let segments = loaded.manifest.tracks.first { $0.type == type }?.segments ?? []
            XCTAssertGreaterThanOrEqual(segments.count, 1, "\(type) committed nothing")
        }
        let layout = ProjectLayout(root: projectURL)
        for mediaDirectory in [layout.screenDirectory, layout.microphoneDirectory] {
            let partials = (try? FileManager.default
                .contentsOfDirectory(atPath: mediaDirectory.path))?
                .filter { $0.hasSuffix(ProjectLayout.partialSuffix) } ?? []
            XCTAssertTrue(partials.isEmpty, "\(mediaDirectory.lastPathComponent): \(partials)")
        }

        let report = await Validator(options: .init(
            verifyChecksums: true, mediaInspector: AVMediaInspector()))
            .validate(projectAt: projectURL)
        XCTAssertTrue(report.journalFinalized)
        XCTAssertTrue(
            report.isHealthy || loaded.manifest.state == .recoverable,
            "\(report.issues)")
    }

    /// (b) The soft threshold journals and warns exactly once per session,
    /// and never escalates to a stop.
    func testLowDiskWarnsExactlyOnce() async throws {
        let projectURL = directory.appendingPathComponent("low.aks")
        let warnings = WarningRecorder()
        // Above the hard floor forever, below the soft one after beat 1:
        // multiple low heartbeats must still produce a single warning.
        let provider = FakeFreeSpaceProvider(sequence: [10_000_000_000], then: 300_000_000)
        let session = makeSession(projectURL: projectURL, provider: provider, warnings: warnings)

        let durationNs: Int64 = 3_500_000_000
        let screen = SyntheticScreenSource(
            width: 320, height: 180, frameRate: 30, durationNs: durationNs, pace: 1)
        let mic = SyntheticAudioSource(channels: 1, durationNs: durationNs, pace: 1)
        try await session.start(screen: screen, microphone: mic, systemAudio: nil)
        await screen.waitUntilFinished()
        await mic.waitUntilFinished()
        let summary = try await session.stop()
        XCTAssertTrue(summary.validation.isHealthy, "\(summary.validation.issues)")

        XCTAssertEqual(warnings.kinds().filter { $0 == "disk.low" }.count, 1, "\(warnings.kinds())")
        XCTAssertFalse(warnings.kinds().contains("disk.full"))
        let loaded = try ProjectPackage.load(at: projectURL)
        let faults = loaded.journal.records(ofType: .fault).compactMap {
            $0.payload["kind"]?.stringValue
        }
        XCTAssertEqual(faults.filter { $0 == "disk.low" }.count, 1, "\(faults)")
    }

    /// (c) The default probe walks up to an existing ancestor, so a project
    /// path that does not exist yet still reports its destination volume.
    func testDefaultProviderResolvesNotYetCreatedPaths() throws {
        let provider = DefaultFreeSpaceProvider()

        let deep = directory.appendingPathComponent("not/yet/created/session.aks")
        XCTAssertFalse(FileManager.default.fileExists(atPath: deep.path))
        let deepFree = try XCTUnwrap(provider.freeBytes(for: deep))
        XCTAssertGreaterThan(deepFree, 0)

        // Same volume as the existing ancestor (allow unrelated disk churn
        // between the two probes).
        let baseFree = try XCTUnwrap(provider.freeBytes(for: directory))
        XCTAssertGreaterThan(baseFree, 0)
        XCTAssertGreaterThan(Double(deepFree) / Double(baseFree), 0.5)
        XCTAssertLessThan(Double(deepFree) / Double(baseFree), 2.0)

        // A wholly fictional root walks all the way up to "/".
        let fictional = URL(fileURLWithPath: "/aks-no-such-volume-\(UUID().uuidString)/a/b")
        XCTAssertNotNil(provider.freeBytes(for: fictional))
    }
}
