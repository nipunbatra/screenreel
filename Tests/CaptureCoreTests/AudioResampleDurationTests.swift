import AVFoundation
import CoreMedia
import XCTest

@testable import CaptureCore

/// Resampler duration preservation: non-1:1 rate conversion must neither create nor
/// destroy time. Ten seconds in — delivered in seeded-random chunk sizes —
/// must come out as ten seconds at 48 kHz, within one converter quantum.
final class AudioResampleDurationTests: XCTestCase {
    private let clock = SessionClock()

    /// SplitMix64 — deterministic across runs.
    private struct Rng {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
        mutating func int(in range: ClosedRange<Int>) -> Int {
            range.lowerBound + Int(next() % UInt64(range.upperBound - range.lowerBound + 1))
        }
    }

    private func makeSampleBuffer(
        format: AVAudioFormat, frames: Int, startFrame: Int, inputRate: Double
    ) throws -> CMSampleBuffer {
        let pcm = try XCTUnwrap(AVAudioPCMBuffer(
            pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)))
        pcm.frameLength = AVAudioFrameCount(frames)
        let data = pcm.audioBufferList.pointee.mBuffers.mData!
            .assumingMemoryBound(to: Float.self)
        for index in 0..<frames {
            data[index] = Float(sin(2 * .pi * 440 * Double(startFrame + index) / inputRate)) * 0.5
        }

        var formatDescription: CMAudioFormatDescription?
        var asbd = format.streamDescription.pointee
        try XCTAssertEqual(noErr, CMAudioFormatDescriptionCreate(
            allocator: nil, asbd: &asbd,
            layoutSize: 0, layout: nil,
            magicCookieSize: 0, magicCookie: nil,
            extensions: nil, formatDescriptionOut: &formatDescription))
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: CMTimeScale(format.sampleRate)),
            presentationTimeStamp: CMTime(
                seconds: Double(startFrame) / inputRate, preferredTimescale: 1_000_000_000),
            decodeTimeStamp: .invalid)
        var sampleBuffer: CMSampleBuffer?
        try XCTAssertEqual(noErr, CMSampleBufferCreate(
            allocator: nil, dataBuffer: nil, dataReady: false,
            makeDataReadyCallback: nil, refcon: nil,
            formatDescription: formatDescription,
            sampleCount: frames,
            sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 0, sampleSizeArray: nil,
            sampleBufferOut: &sampleBuffer))
        let buffer = try XCTUnwrap(sampleBuffer)
        try XCTAssertEqual(noErr, CMSampleBufferSetDataBufferFromAudioBufferList(
            buffer,
            blockBufferAllocator: nil, blockBufferMemoryAllocator: nil,
            flags: 0, bufferList: pcm.audioBufferList))
        return buffer
    }

    /// Push exactly ten seconds at `inputRate` through one converter in
    /// seeded-random chunk sizes; the final chunk is a full 8 192 frames so
    /// the drain loop's multi-pull path runs at the end of the stream.
    private func totalOutputFrames(inputRate: Double, seed: UInt64) throws -> Int {
        let format = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: inputRate,
            channels: 1, interleaved: true))
        let converter = SampleBufferAudioConverter()
        var rng = Rng(state: seed)
        let totalFrames = Int(inputRate) * 10
        let tailFrames = 8_192
        var fed = 0
        var produced = 0
        while fed < totalFrames {
            let remaining = totalFrames - fed
            let frames = remaining <= tailFrames
                ? remaining
                : min(rng.int(in: 64...8_192), remaining - tailFrames)
            let buffer = try makeSampleBuffer(
                format: format, frames: frames, startFrame: fed, inputRate: inputRate)
            if let chunk = converter.chunk(from: buffer, clock: clock) {
                XCTAssertEqual(chunk.sampleRate, 48_000)
                produced += chunk.frameCount
            }
            fed += frames
        }
        XCTAssertEqual(fed, totalFrames)
        return produced
    }

    func testUpsampling24kPreservesTenSecondDuration() throws {
        let produced = try totalOutputFrames(inputRate: 24_000, seed: 0xA5A5_2401)
        // 10 s of 24 k in → 480 000 frames at 48 k, ± one 4 096-frame
        // converter quantum of held latency.
        XCTAssertGreaterThanOrEqual(produced, 480_000 - 4_096)
        XCTAssertLessThanOrEqual(produced, 480_000 + 4_096)
    }

    func testDownsampling96kPreservesTenSecondDuration() throws {
        let produced = try totalOutputFrames(inputRate: 96_000, seed: 0xB6B6_9601)
        XCTAssertGreaterThanOrEqual(produced, 480_000 - 4_096)
        XCTAssertLessThanOrEqual(produced, 480_000 + 4_096)
    }
}
