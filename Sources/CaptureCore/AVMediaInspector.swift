import AVFoundation
import Foundation
import ProjectModel

/// AVFoundation-backed implementation of the `MediaInspecting` boundary:
/// container opens, stream shape matches, and the packet layer reads
/// end-to-end. This is the "basic decode inspection" gate — deep pixel/audio
/// verification belongs to acceptance fixtures, not the commit path.
public struct AVMediaInspector: MediaInspecting {
    public init() {}

    public func probe(url: URL, container: MediaContainer) async -> MediaProbe {
        switch container {
        case .mov:
            return await probeMov(url: url)
        case .caf:
            return probeCaf(url: url)
        }
    }

    private func probeMov(url: URL) async -> MediaProbe {
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        do {
            let duration = try await asset.load(.duration)
            let videoTracks = try await asset.loadTracks(withMediaType: .video)
            guard let track = videoTracks.first else {
                return MediaProbe(decodable: false, issues: ["no video track"])
            }
            let (size, frameRate) = try await track.load(.naturalSize, .nominalFrameRate)

            // Walk every packet without decoding to verify container indexes.
            var frameCount = 0
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
            reader.add(output)
            guard reader.startReading() else {
                return MediaProbe(
                    decodable: false,
                    issues: ["reader failed to start: \(reader.error.map { "\($0)" } ?? "unknown")"])
            }
            while let sample = output.copyNextSampleBuffer() {
                frameCount += CMSampleBufferGetNumSamples(sample)
            }
            if reader.status == .failed {
                return MediaProbe(
                    decodable: false,
                    issues: ["packet read failed: \(reader.error.map { "\($0)" } ?? "unknown")"])
            }
            guard frameCount > 0 else {
                return MediaProbe(decodable: false, issues: ["container has zero samples"])
            }
            let durationNs = Int64(duration.seconds * 1_000_000_000)
            return MediaProbe(
                decodable: true,
                durationNs: durationNs,
                video: VideoFormatInfo(
                    widthPx: Int(size.width),
                    heightPx: Int(size.height),
                    nominalFrameRate: Double(frameRate),
                    frameCount: frameCount))
        } catch {
            return MediaProbe(decodable: false, issues: ["\(error)"])
        }
    }

    private func probeCaf(url: URL) -> MediaProbe {
        do {
            let file = try AVAudioFile(forReading: url)
            let format = file.processingFormat
            let frames = Int(file.length)
            guard frames > 0 else {
                return MediaProbe(decodable: false, issues: ["CAF contains zero frames"])
            }
            let durationNs = Int64(Double(frames) / format.sampleRate * 1_000_000_000)
            return MediaProbe(
                decodable: true,
                durationNs: durationNs,
                audio: AudioFormatInfo(
                    sampleRate: format.sampleRate,
                    channels: Int(format.channelCount),
                    sampleCount: frames))
        } catch {
            return MediaProbe(decodable: false, issues: ["\(error)"])
        }
    }
}
