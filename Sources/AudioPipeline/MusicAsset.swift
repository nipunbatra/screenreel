import AVFoundation
import Foundation
import ProjectModel
import TimelineCore
import Synchronization

public enum MusicAsset {
    /// Copy the original and stream a portable, seekable working copy. No entire-song PCM array.
    public static func importFile(_ source: URL, into layout: ProjectLayout) throws -> BackgroundMusic {
        let fm = FileManager.default
        let directory = layout.root.appendingPathComponent("assets/music")
        guard directory.resolvingSymlinksInPath().path.hasPrefix(layout.root.resolvingSymlinksInPath().path + "/") else {
            throw ScreenreelError.invariantViolated("Music assets folder points outside this project.")
        }
        let id = UUID().uuidString.lowercased()
        let original = directory.appendingPathComponent("\(id)-original.\(source.pathExtension.isEmpty ? "audio" : source.pathExtension)")
        let working = directory.appendingPathComponent("\(id).caf")
        let partial = directory.appendingPathComponent("\(id).partial.caf")
        var committed = false
        defer {
            if !committed {
                for url in [original, working, partial] { try? fm.removeItem(at: url) }
            }
        }
        let input = try AVAudioFile(forReading: source, commonFormat: .pcmFormatFloat32, interleaved: false)
        guard input.length > 0, input.processingFormat.channelCount <= 2 else {
            throw ScreenreelError.invariantViolated("Choose a non-empty mono or stereo music file.")
        }
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        guard let converter = AVAudioConverter(from: input.processingFormat, to: format),
              let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_384) else {
            throw ScreenreelError.invariantViolated("This music format cannot be converted. Try WAV, AIFF, MP3 or M4A.")
        }
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        try Task.checkCancellation()
        try FileCloner.clone(from: source, to: original)
        var settings = format.settings
        settings[AVLinearPCMIsNonInterleaved] = false
        var writer: AVAudioFile? = try AVAudioFile(forWriting: partial, settings: settings)
        let readError = Mutex<(any Error)?>(nil)
        var totalFrames: Int64 = 0
        while true {
            try Task.checkCancellation()
            var conversionError: NSError?
            let status = converter.convert(to: output, error: &conversionError) { requested, result in
                guard input.framePosition < input.length else {
                    result.pointee = .endOfStream
                    return nil
                }
                guard let buffer = AVAudioPCMBuffer(pcmFormat: input.processingFormat,
                    frameCapacity: min(requested, 65_536)) else {
                    result.pointee = .endOfStream
                    return nil
                }
                do {
                    try input.read(into: buffer)
                    result.pointee = buffer.frameLength > 0 ? .haveData : .endOfStream
                    return buffer
                } catch {
                    readError.withLock { $0 = error }
                    result.pointee = .endOfStream
                    return nil
                }
            }
            if let error = readError.withLock({ $0 }) { throw error }
            if let conversionError { throw conversionError }
            if output.frameLength > 0 {
                try writer?.write(from: output)
                totalFrames += Int64(output.frameLength)
            }
            if status == .endOfStream { break }
            guard status != .error, output.frameLength > 0 else {
                throw ScreenreelError.invariantViolated("Music conversion stopped before completion; choose another file.")
            }
        }
        writer = nil // finalize the CAF before publishing the reference
        guard totalFrames > 0 else {
            throw ScreenreelError.invariantViolated("The selected music contains no decodable audio.")
        }
        try Task.checkCancellation()
        try fm.moveItem(at: partial, to: working)
        committed = true
        return BackgroundMusic(path: layout.relativePath(of: working),
            originalPath: layout.relativePath(of: original), name: source.lastPathComponent)
    }
}

/// Reuses one file and one PCM buffer. Memory is independent of song/video duration.
public final class MusicReader {
    private let file: AVAudioFile
    private let buffer: AVAudioPCMBuffer
    private let track: BackgroundMusic
    public let length: Int64
    public static let blockFrames = 24_000

    public init(track: BackgroundMusic, layout: ProjectLayout) throws {
        self.track = track
        file = try AVAudioFile(forReading: track.audioURL(in: layout), commonFormat: .pcmFormatFloat32, interleaved: false)
        guard file.length > 0, file.processingFormat.sampleRate == 48_000,
              file.processingFormat.channelCount == 2 else {
            throw ScreenreelError.invariantViolated("Music working file is invalid. Remove the music and import the original again.")
        }
        length = file.length
        buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
            frameCapacity: AVAudioFrameCount(Self.blockFrames))!
    }

    public func mix(into samples: inout [Float], frames: Int, channels: Int, at outputFrame: Int64) throws {
        precondition(frames <= Self.blockFrames && samples.count >= frames * channels)
        guard track.gain > 0 else { return }
        var offset = 0
        while offset < frames {
            try Task.checkCancellation()
            guard let start = track.sourceFrame(at: outputFrame + Int64(offset), length: length) else { break }
            let count = min(frames - offset, Int(length - start))
            if file.framePosition != start { file.framePosition = start }
            try file.read(into: buffer, frameCount: AVAudioFrameCount(count))
            guard buffer.frameLength == count, let data = buffer.floatChannelData else {
                throw ScreenreelError.invariantViolated("Music file ended unexpectedly. Import it again.")
            }
            for i in 0..<count {
                for channel in 0..<channels {
                    samples[(offset + i) * channels + channel] += data[min(channel, 1)][i] * track.gain
                }
            }
            offset += count
        }
    }
}
