import AVFoundation
import CoreImage
import CoreVideo
import AudioPipeline
import Foundation
import MotionEngine
import PreviewEngine
import RenderGraph
import ProjectModel
import TimelineCore

/// Styled export: renders every output frame through the same
/// `ProjectComposition` the preview uses (background, padding, corners,
/// shadow, smoothed cursor, zoom camera) and encodes with VideoToolbox.
/// Unlike raw assembly this necessarily re-encodes video; audio and the
/// output-safety protocol are shared with `SegmentAssembler`.
public enum StyledExporter {

    public struct Result: Sendable {
        public let outputURL: URL
        public let durationNs: Int64
        public let videoFrames: Int
        public let audioFrames: Int64
        public let warnings: [String]
    }

    public struct Options: Sendable {
        public var fps: Double
        public var codec: MediaCodec
        /// Encode bitrate as bits per pixel per frame. Screen text needs
        /// more than camera video: 0.16 ≈ 45 Mb/s at 4K30, which keeps
        /// small text legible after the padded-card downscale.
        public var bitsPerPixelPerFrame: Double
        /// Output height in pixels; width follows the canvas aspect. Nil uses
        /// the source size.
        public var outputHeight: Int?
        public var includeAudio: Bool
        public var aacBitrate: Int
        public var overwrite: Bool
        /// Render exactly this OUTPUT-time range instead of the project's
        /// trimmed range. The checkpointed exporter uses it to render one
        /// segment per call; PTS stay zero-based within the file either
        /// way. Nil (the default) keeps the normal trimmed-range export.
        public var outputRangeNs: (startNs: Int64, endNs: Int64)?
        public var progress: (@Sendable (String, Double) -> Void)?

        public init(
            fps: Double = 30,
            codec: MediaCodec = .hevc,
            bitsPerPixelPerFrame: Double = 0.16,
            outputHeight: Int? = nil,
            includeAudio: Bool = true,
            aacBitrate: Int = 160_000,
            overwrite: Bool = false,
            outputRangeNs: (startNs: Int64, endNs: Int64)? = nil,
            progress: (@Sendable (String, Double) -> Void)? = nil
        ) {
            self.fps = fps
            self.codec = codec
            self.bitsPerPixelPerFrame = bitsPerPixelPerFrame
            self.outputHeight = outputHeight
            self.includeAudio = includeAudio
            self.aacBitrate = aacBitrate
            self.overwrite = overwrite
            self.outputRangeNs = outputRangeNs
            self.progress = progress
        }
    }

    /// The smallest canvas height at which the un-zoomed screen content
    /// renders at exactly 1.0× (no downscale softening). Solved by
    /// iterating the composer's own geometry so padding/aspect rules can
    /// never drift from the renderer.
    public static func nativeContentHeight(
        sourceSize: SIMD2<Double>, style: FrameStyle
    ) -> Double {
        let aspect = style.canvasAspect ?? (sourceSize.x / max(1, sourceSize.y))
        var height = sourceSize.y
        for _ in 0..<5 {
            let size = SIMD2((height * aspect).rounded(), height.rounded())
            let composer = FrameComposer(
                style: style, outputSize: size, sourceSize: sourceSize)
            let scale = composer.geometry(camera: .identity).contentScale
            if scale >= 0.9995 { break }
            height = (height / scale).rounded()
        }
        // Sanity bound: padding is clamped UI-side; never explode the canvas.
        return min(height, sourceSize.y * 1.8)
    }

    public static func export(
        projectAt projectURL: URL,
        to outputURL: URL,
        options: Options = Options()
    ) async throws -> Result {
        let fm = FileManager.default
        if fm.fileExists(atPath: outputURL.path), !options.overwrite {
            throw AksError.ioFailed(operation: "export", path: outputURL.path, errno: EEXIST)
        }

        let activity = SystemActivity(.export, reason: "Styled export")
        defer { activity.end() }
        let composition = try ProjectComposition(projectURL: projectURL)
        let range = options.outputRangeNs ?? composition.trimmedRange
        let rangeDurationNs = range.endNs - range.startNs
        guard rangeDurationNs > 0 else {
            throw AksError.invariantViolated("trimmed range is empty")
        }

        // Output geometry: even dimensions; canvas aspect from the edit
        // document (16:9/9:16/1:1 reframes) falling back to the source.
        // Default height makes the resting screen content exactly 1:1
        // source pixels — padding grows the canvas outward instead of
        // shrinking the content, so screen text stays pin-sharp at 1:1 source pixels.
        let sourceSize = composition.sourceSize
        let outputHeight = options.outputHeight.map(Double.init)
            ?? Self.nativeContentHeight(
                sourceSize: sourceSize, style: composition.edits.style)
        let aspect = composition.edits.style.canvasAspect ?? (sourceSize.x / sourceSize.y)
        let width = Int((outputHeight * aspect / 2).rounded()) * 2
        let height = Int((outputHeight / 2).rounded()) * 2
        composition.setOutputSize(SIMD2(Double(width), Double(height)))

        let partialURL = outputURL.deletingLastPathComponent()
            .appendingPathComponent(outputURL.lastPathComponent + ".partial.mp4")
        try? fm.removeItem(at: partialURL)
        let writer = try AVAssetWriter(outputURL: partialURL, fileType: .mp4)

        let bitrate = Double(width * height) * options.fps * options.bitsPerPixelPerFrame
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: options.codec == .h264 ? AVVideoCodecType.h264 : .hevc,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: Int(bitrate),
                AVVideoExpectedSourceFrameRateKey: Int(options.fps),
            ],
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
        ])
        videoInput.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
            ])
        writer.add(videoInput)

        var warnings: [String] = []
        let sampleRate = 48_000.0
        let audioSegments = composition.micSegments + composition.systemSegments
        let mixChannels = audioSegments.compactMap { $0.audio?.channels }.max() ?? 1
        var audioInput: AVAssetWriterInput?
        if options.includeAudio, !audioSegments.isEmpty {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: mixChannels,
                AVEncoderBitRateKey: options.aacBitrate,
            ])
            input.expectsMediaDataInRealTime = false
            writer.add(input)
            audioInput = input
        } else if options.includeAudio {
            warnings.append("project has no committed audio segments; exporting silent video")
        }

        guard writer.startWriting() else {
            throw AksError.invariantViolated(
                "export writer failed to start: \(writer.error.map { "\($0)" } ?? "unknown")")
        }
        writer.startSession(atSourceTime: .zero)

        let progress = options.progress
        // ceil, not floor+1: an exact 2.000 s range at 30 fps is 60
        // frames — floor+1 wrote a 61st frame past the audio's end.
        let totalFrames = max(1, Int((Double(rangeDurationNs) / 1e9 * options.fps).rounded(.up)))
        let ciContext = CIContext(options: [.cacheIntermediates: false])

        // Audio pump runs concurrently (multi-input writer interleaving).
        let audioBox = audioInput.map { AudioPumpBox(writer: writer, input: $0) }
        let micSegmentsForAudio = composition.micSegments
        let systemSegmentsForAudio = composition.systemSegments
        let layoutForAudio = composition.layout
        let audioTask: Task<(Int64, Int64), Error>? = audioBox.map { box in
            Task {
                try await Self.pumpTrimmedAudio(
                    micSegments: micSegmentsForAudio,
                    systemSegments: systemSegmentsForAudio,
                    layout: layoutForAudio,
                    box: box,
                    sampleRate: sampleRate, mixChannels: mixChannels,
                    rangeStartNs: range.startNs, rangeEndNs: range.endNs,
                    clipTimeline: composition.clipTimeline,
                    denoiseMic: composition.edits.micNoiseReduction,
                    progress: progress)
            }
        }

        // Video: evaluate the composition at every output frame time.
        var framesWritten = 0
        do {
            for frameIndex in 0..<totalFrames {
                try Task.checkCancellation()
                let outputNs = Int64(Double(frameIndex) / options.fps * 1e9)
                // Range and frames live on the OUTPUT timeline; the
                // composition maps through the clip timeline (cuts).
                let timelineNs = range.startNs + outputNs
                guard let composed = try await composition.frame(
                    atOutput: min(timelineNs, range.endNs - 1))
                else { continue }

                while !videoInput.isReadyForMoreMediaData {
                    if writer.status == .failed {
                        throw AksError.invariantViolated(
                            "export writer failed: \(writer.error.map { "\($0)" } ?? "unknown")")
                    }
                    try await Task.sleep(nanoseconds: 2_000_000)
                }
                guard let pool = adaptor.pixelBufferPool else {
                    throw AksError.invariantViolated("no pixel buffer pool")
                }
                var pixelBufferOut: CVPixelBuffer?
                CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBufferOut)
                guard let pixelBuffer = pixelBufferOut else {
                    throw AksError.invariantViolated("pixel buffer allocation failed")
                }
                ciContext.render(
                    composed, to: pixelBuffer,
                    bounds: CGRect(x: 0, y: 0, width: width, height: height),
                    // BT.709, matching the file's color tags — rendering sRGB
                    // into a 709-tagged file shifted gamma subtly.
                    colorSpace: CGColorSpace(name: CGColorSpace.itur_709))
                let pts = CMTime(value: outputNs, timescale: 1_000_000_000)
                guard adaptor.append(pixelBuffer, withPresentationTime: pts) else {
                    throw AksError.invariantViolated(
                        "encode append failed: \(writer.error.map { "\($0)" } ?? "unknown")")
                }
                framesWritten += 1
                if frameIndex % 30 == 0 {
                    progress?("render", Double(frameIndex) / Double(totalFrames))
                }
            }
        } catch {
            audioTask?.cancel()
            writer.cancelWriting()
            try? fm.removeItem(at: partialURL)
            throw error
        }
        videoInput.markAsFinished()

        var audioFrames: Int64 = 0
        if let audioTask {
            do {
                let (frames, _) = try await audioTask.value
                audioFrames = frames
            } catch {
                writer.cancelWriting()
                try? fm.removeItem(at: partialURL)
                throw error
            }
        }

        await writer.finishWriting()
        guard writer.status == .completed else {
            try? fm.removeItem(at: partialURL)
            throw AksError.invariantViolated(
                "export mux failed: \(writer.error.map { "\($0)" } ?? "status \(writer.status.rawValue)")")
        }

        // Validate before claiming success.
        let probe = await CaptureCoreInspector().probe(url: partialURL)
        guard probe.decodable, let exportedDuration = probe.durationNs else {
            throw AksError.invariantViolated(
                "exported file failed validation: \(probe.issues.joined(separator: "; "))")
        }
        if let count = probe.frameCount, count != framesWritten {
            throw AksError.invariantViolated(
                "exported file has \(count) frames, expected \(framesWritten)")
        }

        if options.overwrite {
            try? fm.removeItem(at: outputURL)
        }
        try AtomicFile.rename(from: partialURL, to: outputURL)
        try AtomicFile.syncDirectory(outputURL.deletingLastPathComponent())
        progress?("render", 1.0)

        return Result(
            outputURL: outputURL,
            durationNs: exportedDuration,
            videoFrames: framesWritten,
            audioFrames: audioFrames,
            warnings: warnings)
    }

    // MARK: - Audio (trim-aware wrapper over the shared timeline readers)

    final class AudioPumpBox: @unchecked Sendable {
        let writer: AVAssetWriter
        let input: AVAssetWriterInput
        init(writer: AVAssetWriter, input: AVAssetWriterInput) {
            self.writer = writer
            self.input = input
        }
    }

    static func pumpTrimmedAudio(
        micSegments: [SegmentDescriptor], systemSegments: [SegmentDescriptor],
        layout: ProjectLayout, box: AudioPumpBox,
        sampleRate: Double, mixChannels: Int,
        rangeStartNs: Int64, rangeEndNs: Int64,
        clipTimeline: ClipTimeline,
        denoiseMic: Bool,
        progress: (@Sendable (String, Double) -> Void)?
    ) async throws -> (Int64, Int64) {
        // Any failure must still finish the audio input: the multi-input
        // writer throttles the VIDEO input against it, so an unfinished
        // audio input after (say) a damaged CAF read livelocks the video
        // pump forever, hiding the real error behind a hang.
        do {
            return try await pumpTrimmedAudioBody(
                micSegments: micSegments, systemSegments: systemSegments,
                layout: layout, box: box,
                sampleRate: sampleRate, mixChannels: mixChannels,
                rangeStartNs: rangeStartNs, rangeEndNs: rangeEndNs,
                clipTimeline: clipTimeline, denoiseMic: denoiseMic,
                progress: progress)
        } catch {
            box.input.markAsFinished()
            throw error
        }
    }

    private static func pumpTrimmedAudioBody(
        micSegments: [SegmentDescriptor], systemSegments: [SegmentDescriptor],
        layout: ProjectLayout, box: AudioPumpBox,
        sampleRate: Double, mixChannels: Int,
        rangeStartNs: Int64, rangeEndNs: Int64,
        clipTimeline: ClipTimeline,
        denoiseMic: Bool,
        progress: (@Sendable (String, Double) -> Void)?
    ) async throws -> (Int64, Int64) {
        let micReader = micSegments.isEmpty
            ? nil
            : try AudioTimelineReader(segments: micSegments, layout: layout, sampleRate: sampleRate)
        let systemReader = systemSegments.isEmpty
            ? nil
            : try AudioTimelineReader(segments: systemSegments, layout: layout, sampleRate: sampleRate)
        let readers = [micReader, systemReader].compactMap { $0 }
        let denoiser = denoiseMic && micReader?.channels == 1
            ? SpectralDenoiser() : nil
        if let denoiser {
            // Swallow the pipeline's constant 512-sample latency up front:
            // feed one frame of silence and discard its output, so the
            // denoised mic stays sample-aligned with video and with the
            // un-denoised system-audio track it is mixed against.
            var priming = [Float](repeating: 0, count: 512)
            denoiser.process(&priming)
        }
        guard let audioFormat = SegmentAssembler.makeAudioFormatDescription(
            sampleRate: sampleRate, channels: mixChannels)
        else {
            throw AksError.invariantViolated("cannot create audio format description")
        }

        let startFrame = Int64((Double(rangeStartNs) / 1e9 * sampleRate).rounded())
        let endFrame = Int64((Double(rangeEndNs) / 1e9 * sampleRate).rounded())
        let blockFrames = 24_000
        var mixBuffer = [Float](repeating: 0, count: blockFrames * mixChannels)
        var position = startFrame
        var written: Int64 = 0
        while position < endFrame {
            try Task.checkCancellation()
            let frames = Int(min(Int64(blockFrames), endFrame - position))
            for index in 0..<(frames * mixChannels) { mixBuffer[index] = 0 }
            for reader in readers {
                var trackBuffer = [Float](repeating: 0, count: frames * reader.channels)
                // Walk the clip timeline: an output block may span a cut,
                // so it reads as one or more SOURCE spans placed
                // contiguously into the block.
                var filled = 0
                var hasSynthesizedSilence = false
                while filled < frames {
                    let outputNs = Int64(
                        (Double(position + Int64(filled)) / sampleRate * 1e9).rounded())
                    let sourceNs = clipTimeline.sourceTime(forOutput: outputNs)
                    let clipIndex = clipTimeline.clipIndex(atOutput: outputNs)
                    let clip = clipTimeline.clips[clipIndex]
                    let remainingInSourceNs = clip.sourceEndNs
                        - clipTimeline.sourceTime(forOutput: outputNs)
                    let remainingInOutputNs = Int64(
                        (Double(remainingInSourceNs) / clip.speed).rounded())
                    let remainingInClipFrames = max(
                        1, Int(Double(remainingInOutputNs) / 1e9 * sampleRate))
                    let take = min(frames - filled, remainingInClipFrames)
                    var span = [Float](repeating: 0, count: take * reader.channels)
                    if abs(clip.speed - 1) < 0.001 {
                        let sourceFrame = Int64(
                            (Double(sourceNs) / 1e9 * sampleRate).rounded())
                        try reader.read(into: &span, frames: take, at: sourceFrame)
                    }
                    // else: sped span — silence by policy (see Clip.speed).
                    if abs(clip.speed - 1) >= 0.001 { hasSynthesizedSilence = true }
                    for index in 0..<(take * reader.channels) {
                        trackBuffer[filled * reader.channels + index] = span[index]
                    }
                    filled += take
                }
                if let denoiser, reader === micReader {
                    // Synthesized sped-span silence must not teach the
                    // noise-floor tracker a zero floor (the gate would then
                    // pass ~1 s of raw noise after every sped span).
                    denoiser.process(
                        &trackBuffer, learning: !hasSynthesizedSilence)
                }
                for frame in 0..<frames {
                    for channel in 0..<mixChannels {
                        let sourceChannel = min(channel, reader.channels - 1)
                        mixBuffer[frame * mixChannels + channel] +=
                            trackBuffer[frame * reader.channels + sourceChannel]
                    }
                }
            }
            for index in 0..<(frames * mixChannels) {
                mixBuffer[index] = max(-1, min(1, mixBuffer[index]))
            }
            let sampleBuffer = try SegmentAssembler.makeAudioSampleBuffer(
                samples: mixBuffer, frames: frames, channels: mixChannels,
                sampleRate: sampleRate, format: audioFormat,
                ptsFrames: position - startFrame)
            try await SegmentAssembler.appendWhenReady(
                sampleBuffer, to: box.input, writer: box.writer)
            position += Int64(frames)
            written += Int64(frames)
        }
        box.input.markAsFinished()
        return (written, readers.map(\.coveredFrames).max() ?? 0)
    }
}

/// Minimal local probe (duration, decodability, frame count) mirroring
/// AVMediaInspector without importing CaptureCore's full surface.
struct CaptureCoreInspector {
    struct Probe {
        var decodable: Bool
        var durationNs: Int64?
        var frameCount: Int?
        var issues: [String]
    }

    func probe(url: URL) async -> Probe {
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        do {
            let duration = try await asset.load(.duration)
            guard let track = try await asset.loadTracks(withMediaType: .video).first else {
                return Probe(decodable: false, durationNs: nil, frameCount: nil, issues: ["no video track"])
            }
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
            reader.add(output)
            guard reader.startReading() else {
                return Probe(
                    decodable: false, durationNs: nil, frameCount: nil,
                    issues: [reader.error.map { "\($0)" } ?? "reader failed"])
            }
            var count = 0
            while let sample = output.copyNextSampleBuffer() {
                count += CMSampleBufferGetNumSamples(sample)
            }
            if reader.status == .failed {
                return Probe(
                    decodable: false, durationNs: nil, frameCount: nil,
                    issues: [reader.error.map { "\($0)" } ?? "read failed"])
            }
            return Probe(
                decodable: count > 0,
                durationNs: Int64(duration.seconds * 1e9),
                frameCount: count,
                issues: count > 0 ? [] : ["zero samples"])
        } catch {
            return Probe(decodable: false, durationNs: nil, frameCount: nil, issues: ["\(error)"])
        }
    }
}
