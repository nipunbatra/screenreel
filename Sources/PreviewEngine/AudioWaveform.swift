import AVFoundation
import Foundation
import ProjectModel

/// Peak-bucket waveform over a track's committed CAF segments, positioned on
/// the project timeline (gaps stay silent buckets).
public enum AudioWaveform {

    /// `buckets` peak values in 0...1 spanning [0, durationNs].
    public static func peaks(
        segments: [SegmentDescriptor],
        layout: ProjectLayout,
        durationNs: Int64,
        buckets: Int = 400
    ) -> [Float] {
        guard durationNs > 0, buckets > 0 else { return [] }
        var result = [Float](repeating: 0, count: buckets)
        for segment in segments {
            guard let url = try? layout.resolve(relativePath: segment.path),
                let file = try? AVAudioFile(forReading: url)
            else { continue }
            let format = file.processingFormat
            let sampleRate = format.sampleRate
            let blockFrames: AVAudioFrameCount = 48_000
            guard let buffer = AVAudioPCMBuffer(
                pcmFormat: format, frameCapacity: blockFrames)
            else { continue }

            var framePosition: AVAudioFramePosition = 0
            while framePosition < file.length {
                file.framePosition = framePosition
                do {
                    try file.read(into: buffer, frameCount: blockFrames)
                } catch {
                    break
                }
                let frames = Int(buffer.frameLength)
                guard frames > 0, let channelData = buffer.floatChannelData else { break }
                let channels = Int(format.channelCount)
                // Sub-block peaks so one read distributes across buckets.
                let subBlock = 1_024
                var offset = 0
                while offset < frames {
                    let count = min(subBlock, frames - offset)
                    var peak: Float = 0
                    for channel in 0..<channels {
                        let data = channelData[channel]
                        for index in offset..<(offset + count) {
                            let magnitude = abs(data[index])
                            if magnitude > peak { peak = magnitude }
                        }
                    }
                    let timeNs = segment.normalizedStartNs
                        + Int64(Double(framePosition + AVAudioFramePosition(offset)) / sampleRate * 1e9)
                    let bucket = Int(Double(timeNs) / Double(durationNs) * Double(buckets))
                    if bucket >= 0 && bucket < buckets {
                        result[bucket] = max(result[bucket], min(1, peak))
                    }
                    offset += count
                }
                framePosition += AVAudioFramePosition(frames)
            }
        }
        return result
    }
}
