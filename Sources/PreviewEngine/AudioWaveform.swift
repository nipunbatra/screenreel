import AVFoundation
import Accelerate
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
        buckets: Int = 400,
        isCancelled: @Sendable () -> Bool = { Task.isCancelled }
    ) -> [Float] {
        guard durationNs > 0, buckets > 0 else { return [] }
        guard !isCancelled() else { return [] }
        var result = [Float](repeating: 0, count: buckets)
        let bucketNs = Double(durationNs) / Double(buckets)
        for segment in segments {
            guard !isCancelled() else { return [] }
            // A recovered file can contain samples outside its committed
            // range. Neither those samples nor audio past the timeline end
            // belongs in the waveform.
            let endNs = min(durationNs, segment.normalizedEndNs)
            guard endNs > max(0, segment.normalizedStartNs) else { continue }
            guard let url = try? layout.resolve(relativePath: segment.path),
                let file = try? AVAudioFile(
                    forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
            else { continue }
            let format = file.processingFormat
            let sampleRate = format.sampleRate
            guard sampleRate.isFinite, sampleRate > 0 else { continue }
            let startNs = Double(segment.normalizedStartNs)
            func frame(at timeNs: Double) -> AVAudioFramePosition {
                let value = ceil((timeNs - startNs) * sampleRate / 1e9)
                return AVAudioFramePosition(max(0, min(Double(file.length), value)))
            }
            let endFrame = frame(at: Double(endNs))
            let blockFrames: AVAudioFrameCount = 48_000
            guard let buffer = AVAudioPCMBuffer(
                pcmFormat: format, frameCapacity: blockFrames)
            else { continue }

            file.framePosition = frame(at: 0)
            var framePosition = file.framePosition
            while framePosition < endFrame {
                guard !isCancelled() else { return [] }
                do {
                    try file.read(into: buffer, frameCount: AVAudioFrameCount(
                        min(Int64(blockFrames), endFrame - framePosition)))
                } catch {
                    break
                }
                let frames = Int(buffer.frameLength)
                guard frames > 0, let channelData = buffer.floatChannelData else { break }
                let channels = Int(format.channelCount)
                var offset = 0
                while offset < frames {
                    let position = framePosition + AVAudioFramePosition(offset)
                    let timeNs = startNs + Double(position) / sampleRate * 1e9
                    let bucket = Int(floor(timeNs / bucketNs))
                    guard bucket >= 0, bucket < buckets else { break }
                    // Split exactly at each bucket boundary. Fixed 1024-frame
                    // groups misplaced transients (or left empty buckets) on
                    // short recordings. vDSP scans each channel without the
                    // old per-sample Swift loop or temporary sample arrays.
                    let nextFrame = frame(at: Double(bucket + 1) * bucketNs)
                    let count = min(frames - offset, Int(max(1, nextFrame - position)))
                    var peak: Float = 0
                    for channel in 0..<channels {
                        let data = channelData[channel].advanced(by: offset)
                        var channelPeak: Float = 0
                        vDSP_maxmgv(data, 1, &channelPeak, vDSP_Length(count))
                        if channelPeak.isNaN {
                            // Damaged float PCM must not poison UI geometry.
                            // Keep the fast path allocation-free for normal audio.
                            channelPeak = 0
                            for index in 0..<count where !data[index].isNaN {
                                channelPeak = max(channelPeak, abs(data[index]))
                            }
                        }
                        peak = max(peak, channelPeak)
                    }
                    result[bucket] = max(result[bucket], min(1, peak))
                    offset += count
                }
                framePosition += AVAudioFramePosition(frames)
            }
        }
        return result
    }
}
