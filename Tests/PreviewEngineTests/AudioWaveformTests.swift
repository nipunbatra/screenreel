import AVFoundation
import Foundation
import ProjectModel
import Synchronization
import XCTest
@testable import PreviewEngine

final class AudioWaveformTests: XCTestCase {
    private var root: URL!
    private var layout: ProjectLayout { ProjectLayout(root: root) }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("waveform-\(UUID())")
        try FileManager.default.createDirectory(at: layout.microphoneDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: root)
    }

    private func write(_ channels: [[Float]], rate: Double = 48_000,
                       start: Int64 = 0, end: Int64? = nil, interleaved: Bool = false) throws -> SegmentDescriptor {
        let url = layout.microphoneDirectory.appendingPathComponent("\(UUID()).caf")
        let format = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: rate,
            channels: AVAudioChannelCount(channels.count), interleaved: interleaved))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(channels[0].count)))
        buffer.frameLength = buffer.frameCapacity
        for channel in channels.indices {
            for index in channels[channel].indices {
                buffer.floatChannelData![interleaved ? 0 : channel][interleaved ? index * channels.count + channel : index] = channels[channel][index]
            }
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings,
                                   commonFormat: .pcmFormatFloat32, interleaved: interleaved)
        try file.write(from: buffer)
        let duration = Int64(Double(channels[0].count) / rate * 1e9)
        return SegmentDescriptor(trackID: UUID(), trackType: .microphone,
            path: "raw/microphone/\(url.lastPathComponent)", sequenceInTrack: 1,
            container: .caf, codec: .pcmFloat32, sourceStartNs: 0, sourceEndNs: duration,
            normalizedStartNs: start, normalizedEndNs: end ?? start + duration,
            byteSize: 0, sha256: "", commitSequence: 1)
    }

    func testEveryShortTimelineBucketContainsItsOwnPeak() throws {
        // 48 samples per bucket: the old 1024-sample groups left 95% empty.
        var samples = [Float](repeating: 0, count: 4_800)
        for bucket in 0..<100 { samples[bucket * 48 + 47] = Float(bucket + 1) / 100 }
        let segment = try write([samples])
        let peaks = AudioWaveform.peaks(segments: [segment], layout: layout, durationNs: 100_000_000, buckets: 100)
        XCTAssertEqual(peaks, (1...100).map { Float($0) / 100 })
    }

    func testBoundaryImpulseDoesNotBleedIntoPreviousBucket() throws {
        var samples = [Float](repeating: 0, count: 4_800)
        samples[480] = -0.85
        let segment = try write([samples])
        XCTAssertEqual(AudioWaveform.peaks(segments: [segment], layout: layout,
            durationNs: 100_000_000, buckets: 10), [0, 0.85, 0, 0, 0, 0, 0, 0, 0, 0])
    }

    func testStereoInterleavedAndPlanarFindTheLouderChannel() throws {
        for interleaved in [false, true] {
            let segment = try write([[Float](repeating: 0.1, count: 4_800),
                                     [Float](repeating: -0.7, count: 4_800)], interleaved: interleaved)
            XCTAssertEqual(AudioWaveform.peaks(segments: [segment], layout: layout,
                durationNs: 100_000_000, buckets: 10), [Float](repeating: 0.7, count: 10))
        }
    }

    func testUnorderedSegmentsPreserveGapsAndMaximizeOverlaps() throws {
        let first = try write([[Float](repeating: 0.2, count: 4_800)])
        let last = try write([[Float](repeating: 0.4, count: 4_800)], start: 200_000_000)
        let overlap = try write([[Float](repeating: 0.8, count: 4_800)], start: 200_000_000)
        XCTAssertEqual(AudioWaveform.peaks(segments: [last, first, overlap], layout: layout,
            durationNs: 400_000_000, buckets: 4), [0.2, 0, 0.8, 0])
    }

    func testSamplesPastCommittedEndAreIgnored() throws {
        var samples = [Float](repeating: 0.1, count: 4_800)
        samples[2_400] = 1
        let segment = try write([samples], end: 50_000_000)
        XCTAssertEqual(AudioWaveform.peaks(segments: [segment], layout: layout,
            durationNs: 100_000_000, buckets: 2), [0.1, 0])
    }

    func testSamplesPastTimelineEndAreIgnored() throws {
        var samples = [Float](repeating: 0.1, count: 4_800)
        samples[2_400] = 1
        let segment = try write([samples])
        XCTAssertEqual(AudioWaveform.peaks(segments: [segment], layout: layout,
            durationNs: 50_000_000, buckets: 1), [0.1])
    }

    func testNegativeStartClipsLeadingSamples() throws {
        var samples = [Float](repeating: 0.3, count: 4_800)
        samples[2_399] = 1
        let segment = try write([samples], start: -50_000_000)
        XCTAssertEqual(AudioWaveform.peaks(segments: [segment], layout: layout,
            durationNs: 100_000_000, buckets: 2), [0.3, 0])
    }

    func testFinalPartialReadAnd44100HzSamplePlacement() throws {
        let rate = 44_100.0
        let count = 50_027
        let buckets = 113
        let duration: Int64 = 1_200_000_000
        var samples = [Float](repeating: 0, count: count)
        var expected = [Float](repeating: 0, count: buckets)
        for index in stride(from: 43, to: count, by: 199) {
            samples[index] = -Float(index % 97 + 1) / 100
            let bucket = Int((Double(index) / rate * 1e9) / Double(duration) * Double(buckets))
            expected[bucket] = max(expected[bucket], abs(samples[index]))
        }
        samples[count - 1] = 0.99
        expected[Int(Double(count - 1) / rate * 1e9 / Double(duration) * Double(buckets))] = 0.99
        let segment = try write([samples], rate: rate)
        XCTAssertEqual(AudioWaveform.peaks(segments: [segment], layout: layout,
            durationNs: duration, buckets: buckets), expected)
    }

    func testInvalidInputAndMissingMediaAreSafe() throws {
        XCTAssertEqual(AudioWaveform.peaks(segments: [], layout: layout, durationNs: 0), [])
        XCTAssertEqual(AudioWaveform.peaks(segments: [], layout: layout, durationNs: 1, buckets: 0), [])
        XCTAssertEqual(AudioWaveform.peaks(segments: [], layout: layout, durationNs: 1, buckets: 3), [0, 0, 0])
        var segment = try write([[0.4, 0.5]])
        segment.path = "raw/microphone/missing.caf"
        XCTAssertEqual(AudioWaveform.peaks(segments: [segment], layout: layout, durationNs: 1_000_000, buckets: 2), [0, 0])
    }

    func testDamagedPCMDoesNotReturnNaNOrOutOfRangePeaks() throws {
        let segment = try write([[Float.nan, -0.6, .infinity, -2]])
        let peaks = AudioWaveform.peaks(segments: [segment], layout: layout,
            durationNs: 1_000_000, buckets: 1)
        XCTAssertEqual(peaks, [1])
    }

    func testCancellationStopsBeforeReadingAndBetweenBlocks() throws {
        let segment = try write([[Float](repeating: 0.5, count: 480_000)])
        XCTAssertEqual(AudioWaveform.peaks(segments: [segment], layout: layout,
            durationNs: 10_000_000_000, isCancelled: { true }), [])
        let checks = Mutex(0)
        let peaks = AudioWaveform.peaks(segments: [segment], layout: layout,
            durationNs: 10_000_000_000, isCancelled: {
                checks.withLock { $0 += 1; return $0 >= 4 }
            })
        XCTAssertEqual(peaks, [], "Never publish a partially computed waveform after cancellation")
        XCTAssertEqual(checks.withLock { $0 }, 4)
    }

    func testTaskCancellationIsObservedByDefault() async throws {
        let segment = try write([[Float](repeating: 0.5, count: 4_800)])
        let layout = self.layout
        let task = Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            return AudioWaveform.peaks(segments: [segment], layout: layout, durationNs: 100_000_000)
        }
        let result = await task.value
        XCTAssertEqual(result, [])
    }
}
