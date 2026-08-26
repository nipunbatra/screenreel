@preconcurrency import AVFoundation
import CoreMedia
import Foundation

/// Converts capture audio CMSampleBuffers — whatever their true layout
/// (interleaved/planar, float/int, any rate) — into 48 kHz interleaved
/// float32 `AudioChunk`s.
///
/// The extraction uses `CMSampleBufferCopyPCMDataIntoAudioBufferList` with an
/// `AVAudioFormat` built from the buffer's own ASBD, and conversion goes
/// through `AVAudioConverter`, so no byte-layout assumptions are hand-rolled
/// anywhere. (The first release interpreted buffers manually and produced
/// static for device formats it guessed wrong.)
final class SampleBufferAudioConverter {
    static let outputSampleRate = 48_000.0

    private var sourceFormat: AVAudioFormat?
    private var converter: AVAudioConverter?
    private var outputFormat: AVAudioFormat?

    /// Nanoseconds of output produced so far; used to derive gap-free output
    /// timestamps after resampling changes the frame count.
    private(set) var convertedFrames: Int64 = 0

    func chunk(from sampleBuffer: CMSampleBuffer, clock: SessionClock) -> AudioChunk? {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
            var asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription)?.pointee
        else { return nil }
        let frameCount = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frameCount > 0 else { return nil }

        // (Re)build the converter when the source format changes mid-stream
        // (route change, device swap).
        if sourceFormat == nil || sourceFormat?.streamDescription.pointee != asbd {
            guard let source = AVAudioFormat(streamDescription: &asbd) else { return nil }
            let channels = min(2, max(1, Int(asbd.mChannelsPerFrame)))
            guard let output = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: Self.outputSampleRate,
                channels: AVAudioChannelCount(channels),
                interleaved: true)
            else { return nil }
            sourceFormat = source
            outputFormat = output
            converter = AVAudioConverter(from: source, to: output)
        }
        guard let sourceFormat, let outputFormat, let converter else { return nil }

        // Copy the PCM out of the sample buffer into a source-format buffer.
        guard let input = AVAudioPCMBuffer(
            pcmFormat: sourceFormat, frameCapacity: AVAudioFrameCount(frameCount))
        else { return nil }
        input.frameLength = AVAudioFrameCount(frameCount)
        let copyStatus = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer, at: 0, frameCount: Int32(frameCount),
            into: input.mutableAudioBufferList)
        guard copyStatus == noErr else { return nil }

        // Convert (format + rate) into interleaved float32 at 48 kHz,
        // draining the converter fully: it processes in internal quanta and a
        // single pull can return a partial result.
        // The input block runs synchronously inside convert(); the box only
        // exists to satisfy Sendable checking.
        final class InputBox: @unchecked Sendable {
            var fed = false
            let buffer: AVAudioPCMBuffer
            init(_ buffer: AVAudioPCMBuffer) { self.buffer = buffer }
        }
        let box = InputBox(input)
        let channels = Int(outputFormat.channelCount)
        var samples: [Float] = []
        samples.reserveCapacity(
            Int((Double(frameCount) * Self.outputSampleRate / asbd.mSampleRate).rounded(.up) + 64)
                * channels)
        drain: while true {
            guard let output = AVAudioPCMBuffer(
                pcmFormat: outputFormat, frameCapacity: 4_096)
            else { break }
            var conversionError: NSError?
            let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
                if box.fed {
                    inputStatus.pointee = .noDataNow
                    return nil
                }
                box.fed = true
                inputStatus.pointee = .haveData
                return box.buffer
            }
            if status == .error { break }
            let produced = Int(output.frameLength)
            if produced > 0,
                let data = output.audioBufferList.pointee.mBuffers.mData
            {
                // Interleaved float32: all samples live in the first buffer.
                let floats = data.assumingMemoryBound(to: Float.self)
                samples.append(contentsOf: UnsafeBufferPointer(
                    start: floats, count: produced * channels))
            }
            switch status {
            case .haveData where produced == 4_096:
                continue  // buffer filled; more may be pending
            default:
                break drain  // input consumed (or nothing further available)
            }
        }
        guard !samples.isEmpty else { return nil }
        let outputFrames = samples.count / channels

        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard pts.isNumeric else { return nil }
        let hostNs = Int64(pts.seconds * 1_000_000_000)
        convertedFrames += Int64(outputFrames)
        return AudioChunk(
            samples: samples,
            frameCount: outputFrames,
            channels: channels,
            sampleRate: Self.outputSampleRate,
            ptsNs: clock.normalizeHostNs(hostNs),
            sourceNs: hostNs)
    }
}

extension AudioStreamBasicDescription: @retroactive Equatable {
    public static func == (lhs: AudioStreamBasicDescription, rhs: AudioStreamBasicDescription) -> Bool {
        lhs.mSampleRate == rhs.mSampleRate
            && lhs.mFormatID == rhs.mFormatID
            && lhs.mFormatFlags == rhs.mFormatFlags
            && lhs.mBytesPerPacket == rhs.mBytesPerPacket
            && lhs.mFramesPerPacket == rhs.mFramesPerPacket
            && lhs.mBytesPerFrame == rhs.mBytesPerFrame
            && lhs.mChannelsPerFrame == rhs.mChannelsPerFrame
            && lhs.mBitsPerChannel == rhs.mBitsPerChannel
    }
}
