import AVFoundation
import Foundation
import ProjectModel

/// Streams one audio track's committed CAF segments as a continuous timeline:
/// requested ranges inside a segment come from the file, ranges in gaps come
/// back as silence — gaps are explicit and never stretched
/// (`docs/AUDIO_PIPELINE.md` §3, §8 gap policy).
final class AudioTimelineReader {
    private struct Slice {
        let startNs: Int64
        let endNs: Int64
        let startFrame: Int64
        let frameCount: Int64
        let url: URL
    }

    private let slices: [Slice]
    private let sampleRate: Double
    let channels: Int
    private var openFile: (url: URL, file: AVAudioFile)?

    init(segments: [SegmentDescriptor], layout: ProjectLayout, sampleRate: Double) throws {
        for segment in segments {
            if let rate = segment.audio?.sampleRate, abs(rate - sampleRate) > 0.5 {
                throw ScreenreelError.invariantViolated(
                    "audio segment \(segment.path) is \(Int(rate)) Hz but the export pipeline runs at \(Int(sampleRate)) Hz; resampling is not implemented — re-record at \(Int(sampleRate)) Hz")
            }
        }
        self.sampleRate = sampleRate
        var channels = 1
        var slices: [Slice] = []
        for segment in segments.sorted(by: { $0.sequenceInTrack < $1.sequenceInTrack }) {
            guard let audio = segment.audio, let sampleCount = audio.sampleCount else { continue }
            channels = max(channels, audio.channels)
            slices.append(Slice(
                startNs: segment.normalizedStartNs,
                endNs: segment.normalizedEndNs,
                startFrame: Int64((Double(segment.normalizedStartNs) / 1e9 * sampleRate).rounded()),
                frameCount: Int64(sampleCount),
                url: try layout.resolve(relativePath: segment.path)))
        }
        self.channels = channels
        self.slices = slices
    }

    /// Last timeline frame covered by any segment.
    var endFrame: Int64 {
        slices.map { $0.startFrame + $0.frameCount }.max() ?? 0
    }

    /// Frames actually backed by recorded audio (the rest of the timeline is
    /// gap silence).
    var coveredFrames: Int64 {
        slices.reduce(0) { $0 + $1.frameCount }
    }

    /// Fill `frames` frames starting at timeline frame `position` into an
    /// interleaved float32 buffer (already zeroed regions stay silent).
    func read(into buffer: inout [Float], frames: Int, at position: Int64) throws {
        precondition(buffer.count >= frames * channels)
        for index in buffer.indices.prefix(frames * channels) {
            buffer[index] = 0
        }
        for slice in slices {
            let sliceEnd = slice.startFrame + slice.frameCount
            let overlapStart = max(position, slice.startFrame)
            let overlapEnd = min(position + Int64(frames), sliceEnd)
            guard overlapStart < overlapEnd else { continue }

            let file = try openFileFor(slice)
            let sourceFormat = file.processingFormat
            let sourceChannels = Int(sourceFormat.channelCount)
            let count = Int(overlapEnd - overlapStart)
            file.framePosition = overlapStart - slice.startFrame
            guard let pcm = AVAudioPCMBuffer(
                pcmFormat: sourceFormat, frameCapacity: AVAudioFrameCount(count))
            else { continue }
            try file.read(into: pcm, frameCount: AVAudioFrameCount(count))
            guard let channelData = pcm.floatChannelData else { continue }

            let destinationOffset = Int(overlapStart - position)
            let read = Int(pcm.frameLength)
            for frame in 0..<read {
                for channel in 0..<channels {
                    let sourceChannel = min(channel, sourceChannels - 1)
                    buffer[(destinationOffset + frame) * channels + channel] +=
                        channelData[sourceChannel][frame]
                }
            }
        }
    }

    private func openFileFor(_ slice: Slice) throws -> AVAudioFile {
        if let openFile, openFile.url == slice.url {
            return openFile.file
        }
        let file = try AVAudioFile(forReading: slice.url)
        openFile = (slice.url, file)
        return file
    }
}
