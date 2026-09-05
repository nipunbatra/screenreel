import AVFoundation
import XCTest

@testable import CaptureCore
@testable import ProjectModel

final class ClockAndCAFTests: XCTestCase {
    private var directory: URL!

    override func setUp() {
        super.setUp()
        AtomicFile.fullFsync = false
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("screenreel-cc-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        AtomicFile.fullFsync = true
        super.tearDown()
    }

    // MARK: - SessionClock

    func testClockIsMonotonicAndStartsNearZero() {
        let clock = SessionClock()
        let first = clock.nowNs()
        XCTAssertGreaterThanOrEqual(first, 0)
        XCTAssertLessThan(first, 1_000_000_000)
        let second = clock.nowNs()
        XCTAssertGreaterThanOrEqual(second, first)
    }

    func testHostNormalizationAgainstAnchor() {
        let clock = SessionClock()
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        let nowTicks = mach_absolute_time()
        let normalized = clock.normalizeAbsoluteTicks(nowTicks)
        // The anchor was captured moments ago, so normalization should give a
        // small positive value consistent with nowNs().
        XCTAssertGreaterThanOrEqual(normalized, 0)
        XCTAssertLessThan(abs(normalized - clock.nowNs()), 100_000_000)
    }

    func testAnchorRoundTripThroughManifest() {
        let clock = SessionClock()
        let rehydrated = SessionClock(anchor: clock.anchor)
        let hostNs = Int64(clock_gettime_nsec_np(CLOCK_UPTIME_RAW))
        XCTAssertEqual(
            clock.normalizeHostNs(hostNs), rehydrated.normalizeHostNs(hostNs))
    }

    // MARK: - CAFWriter

    func testCAFRoundTripThroughAVAudioFile() throws {
        let url = directory.appendingPathComponent("test.caf")
        let writer = try CAFWriter(url: url, sampleRate: 48_000, channels: 1)
        let frames = 4_800
        var samples = [Float](repeating: 0, count: frames)
        for index in 0..<frames {
            samples[index] = sin(2 * .pi * 440 * Double(index) / 48_000).sign == .minus ? -0.5 : 0.5
        }
        try writer.append(samples: samples.map { Float($0) })
        try writer.close()

        let expectedSize = CAFWriter.pcmDataOffset + Int64(frames * 4)
        let actualSize = try FileManager.default
            .attributesOfItem(atPath: url.path)[.size] as? Int64
        XCTAssertEqual(actualSize, expectedSize)

        let file = try AVAudioFile(forReading: url)
        XCTAssertEqual(file.length, AVAudioFramePosition(frames))
        XCTAssertEqual(file.processingFormat.sampleRate, 48_000)
        XCTAssertEqual(file.processingFormat.channelCount, 1)

        let buffer = AVAudioPCMBuffer(
            pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(frames))!
        try file.read(into: buffer)
        XCTAssertEqual(buffer.floatChannelData![0][0], 0.5, accuracy: 0.0001)
    }

    /// The torn-tail guarantee: truncate a CAF mid-data and it must still
    /// open, exposing every complete frame written before the cut.
    func testTruncatedCAFRemainsReadable() throws {
        let url = directory.appendingPathComponent("torn.caf")
        let writer = try CAFWriter(url: url, sampleRate: 48_000, channels: 2)
        try writer.append(samples: [Float](repeating: 0.25, count: 48_000 * 2))
        try writer.close()

        // Cut the file mid-way through the PCM data, mid-frame.
        let handle = try FileHandle(forWritingTo: url)
        let cutOffset = UInt64(CAFWriter.pcmDataOffset) + 24_001 * 8 + 3
        try handle.truncate(atOffset: cutOffset)
        try handle.close()

        let file = try AVAudioFile(forReading: url)
        XCTAssertEqual(file.length, 24_001)  // complete frames only
    }

    func testAVMediaInspectorProbesCAF() async throws {
        let url = directory.appendingPathComponent("probe.caf")
        let writer = try CAFWriter(url: url, sampleRate: 48_000, channels: 1)
        try writer.append(samples: [Float](repeating: 0.1, count: 9_600))
        try writer.close()

        let probe = await AVMediaInspector().probe(url: url, container: .caf)
        XCTAssertTrue(probe.decodable)
        XCTAssertEqual(probe.audio?.sampleCount, 9_600)
        XCTAssertEqual(probe.durationNs.map { Double($0) / 1e9 } ?? 0, 0.2, accuracy: 0.001)
    }

    func testAVMediaInspectorRejectsGarbage() async throws {
        let url = directory.appendingPathComponent("junk.mov")
        try Data("not a movie".utf8).write(to: url)
        let probe = await AVMediaInspector().probe(url: url, container: .mov)
        XCTAssertFalse(probe.decodable)
    }
}
