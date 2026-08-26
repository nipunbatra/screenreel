import AVFoundation
import CoreMedia
import XCTest

@testable import CaptureCore

/// The real-capture static-audio bug came from hand-interpreting sample
/// buffer layouts. These tests feed a pure 440 Hz sine through the converter
/// in every layout a device might use — interleaved/planar, float/int,
/// 48 k/44.1 k/24 k — and assert the OUTPUT is still a clean sine:
/// high lag-1 autocorrelation (garbage ≈ 0), correct RMS, correct pitch.
final class AudioConverterTests: XCTestCase {
    private let clock = SessionClock()

    // MARK: - Sample buffer construction

    private func makeSampleBuffer(
        format: AVAudioFormat, frames: Int,
        fill: (AVAudioPCMBuffer) -> Void
    ) throws -> CMSampleBuffer {
        let pcm = try XCTUnwrap(AVAudioPCMBuffer(
            pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)))
        pcm.frameLength = AVAudioFrameCount(frames)
        fill(pcm)

        var formatDescription: CMAudioFormatDescription?
        var asbd = format.streamDescription.pointee
        try XCTAssertEqual(noErr, CMAudioFormatDescriptionCreate(
            allocator: nil, asbd: &asbd,
            layoutSize: 0, layout: nil,
            magicCookieSize: 0, magicCookie: nil,
            extensions: nil, formatDescriptionOut: &formatDescription))

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: CMTimeScale(format.sampleRate)),
            presentationTimeStamp: CMTime(seconds: 1.0, preferredTimescale: 1_000_000_000),
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

    // MARK: - Signal analysis

    private struct Analysis {
        var rms: Double
        var lag1Autocorrelation: Double
        var zeroCrossingRate: Double
    }

    private func analyze(_ chunk: AudioChunk, channel: Int = 0) -> Analysis {
        let channels = chunk.channels
        var mono: [Double] = []
        mono.reserveCapacity(chunk.frameCount)
        for frame in 0..<chunk.frameCount {
            mono.append(Double(chunk.samples[frame * channels + channel]))
        }
        let rms = (mono.reduce(0) { $0 + $1 * $1 } / Double(mono.count)).squareRoot()
        var num = 0.0
        var den = 0.0
        var crossings = 0
        for index in 0..<(mono.count - 1) {
            num += mono[index] * mono[index + 1]
            den += mono[index] * mono[index]
            if (mono[index] >= 0) != (mono[index + 1] >= 0) { crossings += 1 }
        }
        return Analysis(
            rms: rms,
            lag1Autocorrelation: den > 0 ? num / den : 0,
            zeroCrossingRate: Double(crossings) / Double(mono.count))
    }

    private func assertCleanSine(
        _ chunk: AudioChunk,
        expectedRMS: Double = 0.5 * 0.7071,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(chunk.sampleRate, 48_000, file: file, line: line)
        let analysis = analyze(chunk)
        // A 440 Hz sine at 48 kHz: autocorr ≈ cos(2π·440/48000) ≈ 0.998;
        // static/garbage sits near 0.
        XCTAssertGreaterThan(analysis.lag1Autocorrelation, 0.98, file: file, line: line)
        XCTAssertEqual(analysis.rms, expectedRMS, accuracy: 0.05, file: file, line: line)
        // Two crossings per cycle: 2·440/48000 ≈ 0.0183.
        XCTAssertEqual(analysis.zeroCrossingRate, 2 * 440 / 48_000, accuracy: 0.006,
            file: file, line: line)
    }

    // MARK: - Format matrix

    /// Feed a continuous sine as consecutive buffers through ONE converter —
    /// exactly how capture streams — and analyze the concatenated output.
    /// (The converter legitimately holds a processing quantum across calls.)
    private func streamThrough(
        format: AVAudioFormat, framesPerBuffer: Int, buffers: Int,
        fill: (AVAudioPCMBuffer, _ base: Int) -> Void
    ) throws -> AudioChunk {
        let converter = SampleBufferAudioConverter()
        var samples: [Float] = []
        var channels = 1
        var frames = 0
        for bufferIndex in 0..<buffers {
            let sampleBuffer = try makeSampleBuffer(format: format, frames: framesPerBuffer) {
                fill($0, bufferIndex * framesPerBuffer)
            }
            if let chunk = converter.chunk(from: sampleBuffer, clock: clock) {
                samples.append(contentsOf: chunk.samples)
                channels = chunk.channels
                frames += chunk.frameCount
            }
        }
        return AudioChunk(
            samples: samples, frameCount: frames, channels: channels,
            sampleRate: SampleBufferAudioConverter.outputSampleRate, ptsNs: 0)
    }

    func testFloat32Interleaved48k() throws {
        let format = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: true))
        let total = try streamThrough(format: format, framesPerBuffer: 4_800, buffers: 3) { pcm, base in
            let data = pcm.audioBufferList.pointee.mBuffers.mData!
                .assumingMemoryBound(to: Float.self)
            for index in 0..<4_800 {
                data[index] = Float(sin(2 * .pi * 440 * Double(base + index) / 48_000)) * 0.5
            }
        }
        // All frames minus at most one held processing quantum.
        XCTAssertGreaterThanOrEqual(total.frameCount, 3 * 4_800 - 4_096)
        XCTAssertLessThanOrEqual(total.frameCount, 3 * 4_800 + 64)
        assertCleanSine(total)
    }

    func testFloat32Planar48kStereo() throws {
        let format = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: false))
        let buffer = try makeSampleBuffer(format: format, frames: 4_800) { pcm in
            for channel in 0..<2 {
                let data = pcm.floatChannelData![channel]
                for index in 0..<4_800 {
                    data[index] = Float(sin(2 * .pi * 440 * Double(index) / 48_000)) * 0.5
                }
            }
        }
        let chunk = try XCTUnwrap(
            SampleBufferAudioConverter().chunk(from: buffer, clock: clock))
        XCTAssertEqual(chunk.channels, 2)
        assertCleanSine(chunk)
        // Both channels intact, not swapped into garbage.
        let right = analyze(chunk, channel: 1)
        XCTAssertGreaterThan(right.lag1Autocorrelation, 0.98)
    }

    func testInt16Interleaved44_1kResamples() throws {
        let format = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatInt16, sampleRate: 44_100, channels: 1, interleaved: true))
        let total = try streamThrough(format: format, framesPerBuffer: 4_410, buffers: 3) { pcm, base in
            let data = pcm.audioBufferList.pointee.mBuffers.mData!
                .assumingMemoryBound(to: Int16.self)
            for index in 0..<4_410 {
                let phase: Double = 2.0 * Double.pi * 440.0 * Double(base + index) / 44_100.0
                let value: Double = sin(phase) * 0.5 * 32_767.0
                data[index] = Int16(value)
            }
        }
        // 0.3 s of 44.1 k input → ~0.3 s of 48 k output, minus held quantum.
        XCTAssertGreaterThanOrEqual(total.frameCount, 3 * 4_800 - 4_096)
        XCTAssertLessThanOrEqual(total.frameCount, 3 * 4_800 + 64)
        assertCleanSine(total)
    }

    func testInt32Planar24kResamples() throws {
        var asbd = AudioStreamBasicDescription(
            mSampleRate: 24_000,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger
                | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
            mChannelsPerFrame: 1, mBitsPerChannel: 32, mReserved: 0)
        let format = try XCTUnwrap(AVAudioFormat(streamDescription: &asbd))
        let total = try streamThrough(format: format, framesPerBuffer: 2_400, buffers: 4) { pcm, base in
            let data = pcm.audioBufferList.pointee.mBuffers.mData!
                .assumingMemoryBound(to: Int32.self)
            for index in 0..<2_400 {
                let phase: Double = 2.0 * Double.pi * 440.0 * Double(base + index) / 24_000.0
                let value: Double = sin(phase) * 0.5 * Double(Int32.max)
                data[index] = Int32(value)
            }
        }
        // 0.4 s of 24 k input → ~0.4 s of 48 k output, minus held quantum.
        XCTAssertGreaterThanOrEqual(total.frameCount, 4 * 4_800 - 4_096)
        XCTAssertLessThanOrEqual(total.frameCount, 4 * 4_800 + 64)
        assertCleanSine(total)
    }

    func testMidStreamFormatChangeRebuildsConverter() throws {
        let converter = SampleBufferAudioConverter()
        let float48 = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: true))
        let int44 = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatInt16, sampleRate: 44_100, channels: 1, interleaved: true))

        let first = try makeSampleBuffer(format: float48, frames: 4_800) { pcm in
            let data = pcm.audioBufferList.pointee.mBuffers.mData!
                .assumingMemoryBound(to: Float.self)
            for index in 0..<4_800 {
                data[index] = Float(sin(2 * .pi * 440 * Double(index) / 48_000)) * 0.5
            }
        }
        let second = try makeSampleBuffer(format: int44, frames: 4_410) { pcm in
            let data = pcm.audioBufferList.pointee.mBuffers.mData!
                .assumingMemoryBound(to: Int16.self)
            for index in 0..<4_410 {
                let phase: Double = 2.0 * Double.pi * 440.0 * Double(index) / 44_100.0
                let value: Double = sin(phase) * 0.5 * 32_767.0
                data[index] = Int16(value)
            }
        }
        let chunkA = try XCTUnwrap(converter.chunk(from: first, clock: clock))
        let chunkB = try XCTUnwrap(converter.chunk(from: second, clock: clock))
        assertCleanSine(chunkA)
        assertCleanSine(chunkB)
    }
}
