import AVFoundation
import CaptureCore
import CoreMedia
import Foundation
import ProjectModel

/// Assembles a `.aks` project's committed raw segments into one playable MP4:
/// video is stream-copied (no re-encode, no generation loss), audio tracks
/// are mixed in float and AAC-encoded, and gaps become explicit silence
/// (`docs/AUDIO_PIPELINE.md` §8).
///
/// This is the Milestone 0.5 "raw assembly" exporter (ADR 0005): no effects,
/// no cursor, no zooms — those arrive with the editor milestones. It shares
/// the export invariants: raw media is never touched, the destination is
/// written to `.partial` and renamed only after validation, and a failure
/// leaves the project and any existing destination file intact.
///
/// Concurrency note: a multi-input AVAssetWriter interleaves by timestamp and
/// throttles each input until the others catch up, so the video and audio
/// pumps MUST run concurrently — pumping one to completion first deadlocks.
public enum SegmentAssembler {

    public struct Result: Sendable {
        public let outputURL: URL
        public let durationNs: Int64
        public let videoFrames: Int
        public let videoSegments: Int
        public let audioFrames: Int64
        public let silenceFramesInserted: Int64
        public let warnings: [String]
    }

    public struct Options: Sendable {
        public var includeAudio: Bool
        public var aacBitrate: Int
        public var overwrite: Bool
        public var progress: (@Sendable (String, Double) -> Void)?

        public init(
            includeAudio: Bool = true,
            aacBitrate: Int = 160_000,
            overwrite: Bool = false,
            progress: (@Sendable (String, Double) -> Void)? = nil
        ) {
            self.includeAudio = includeAudio
            self.aacBitrate = aacBitrate
            self.overwrite = overwrite
            self.progress = progress
        }
    }

    /// Single-ownership handoff of AVFoundation writer objects into the
    /// concurrent pump tasks.
    private final class WriterBox: @unchecked Sendable {
        let writer: AVAssetWriter
        let videoInput: AVAssetWriterInput
        let audioInput: AVAssetWriterInput?

        init(writer: AVAssetWriter, videoInput: AVAssetWriterInput, audioInput: AVAssetWriterInput?) {
            self.writer = writer
            self.videoInput = videoInput
            self.audioInput = audioInput
        }
    }

    private struct VideoPumpResult: Sendable {
        var frames: Int
        var warnings: [String]
    }

    public static func assemble(
        projectAt projectURL: URL,
        to outputURL: URL,
        options: Options = Options()
    ) async throws -> Result {
        var warnings: [String] = []
        let fm = FileManager.default
        if fm.fileExists(atPath: outputURL.path), !options.overwrite {
            throw AksError.ioFailed(operation: "export", path: outputURL.path, errno: EEXIST)
        }

        // Journal-committed descriptors are the source of truth, exactly as
        // in validation and recovery.
        let loaded = try ProjectPackage.load(at: projectURL)
        if let reason = loaded.journal.truncationReason {
            throw AksError.journalInvalid(
                reason: "journal is damaged (\(reason)); run `aks recover` and export the recovered copy",
                atLine: loaded.journal.truncatedAtLine ?? 0)
        }
        if let lock = loaded.sessionLock {
            throw AksError.sessionActive(path: projectURL.path, pid: lock.pid)
        }
        let layout = loaded.layout

        var segmentsByTrack: [UUID: [SegmentDescriptor]] = [:]
        for record in loaded.journal.records where record.type == .segmentCommitted {
            if let segment = try? record.payload.decoded(as: SegmentDescriptor.self) {
                segmentsByTrack[segment.trackID, default: []].append(segment)
            }
        }
        func track(_ type: TrackType) -> [SegmentDescriptor] {
            loaded.manifest.tracks
                .filter { $0.type == type }
                .flatMap { segmentsByTrack[$0.id] ?? [] }
                .sorted { $0.sequenceInTrack < $1.sequenceInTrack }
        }
        let videoSegments = track(.screen)
        guard !videoSegments.isEmpty else {
            throw AksError.invariantViolated("project has no committed screen segments to export")
        }
        let micSegments = track(.microphone)
        let systemSegments = track(.systemAudio)
        let lastVideoEndNs = videoSegments.map(\.normalizedEndNs).max() ?? 0

        // Writer setup.
        let partialURL = outputURL.deletingLastPathComponent()
            .appendingPathComponent(outputURL.lastPathComponent + ".partial.mp4")
        try? fm.removeItem(at: partialURL)
        let writer = try AVAssetWriter(outputURL: partialURL, fileType: .mp4)
        var outputCommitted = false
        defer {
            if !outputCommitted {
                writer.cancelWriting()
                try? fm.removeItem(at: partialURL)
            }
        }

        // Video: passthrough input with the first segment's format as hint.
        let firstSegmentURL = try layout.resolve(relativePath: videoSegments[0].path)
        guard let formatHint = try await videoFormatDescription(of: firstSegmentURL) else {
            throw AksError.invariantViolated("cannot read video format from \(videoSegments[0].path)")
        }
        let videoInput = AVAssetWriterInput(
            mediaType: .video, outputSettings: nil, sourceFormatHint: formatHint)
        videoInput.expectsMediaDataInRealTime = false
        writer.add(videoInput)

        // Audio: one AAC track mixing microphone + system audio.
        let sampleRate = 48_000.0
        let allAudioSegments = micSegments + systemSegments
        let mixChannels = allAudioSegments
            .compactMap { $0.audio?.channels }.max() ?? 1
        var audioInput: AVAssetWriterInput?
        if options.includeAudio, !allAudioSegments.isEmpty {
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

        let box = WriterBox(writer: writer, videoInput: videoInput, audioInput: audioInput)
        let progress = options.progress

        // Concurrent pumps (see the concurrency note above).
        async let videoResultTask: VideoPumpResult = pumpVideo(
            segments: videoSegments, layout: layout, box: box, progress: progress)
        var audioFrames: Int64 = 0
        var coveredAudioFrames: Int64 = 0
        if audioInput != nil {
            let audio = try await pumpAudio(
                micSegments: micSegments, systemSegments: systemSegments,
                layout: layout, box: box,
                sampleRate: sampleRate, mixChannels: mixChannels,
                minimumEndNs: lastVideoEndNs, progress: progress)
            audioFrames = audio.frames
            coveredAudioFrames = audio.covered
        }
        let videoResult = try await videoResultTask
        warnings.append(contentsOf: videoResult.warnings)

        await writer.finishWriting()
        guard writer.status == .completed else {
            try? fm.removeItem(at: partialURL)
            throw AksError.invariantViolated(
                "export mux failed: \(writer.error.map { "\($0)" } ?? "status \(writer.status.rawValue)")")
        }

        // Validate before claiming success (PRODUCT_SPEC §9: success means
        // the file exists, is readable, and passes duration checks).
        let probe = await AVMediaInspector().probe(url: partialURL, container: .mov)
        guard probe.decodable, let exportedDuration = probe.durationNs else {
            throw AksError.invariantViolated(
                "exported file failed validation: \(probe.issues.joined(separator: "; "))")
        }
        if abs(exportedDuration - lastVideoEndNs) > 100_000_000 {
            warnings.append(
                "exported duration \(Double(exportedDuration) / 1e9)s vs project \(Double(lastVideoEndNs) / 1e9)s")
        }
        if let frameCount = probe.video?.frameCount, frameCount != videoResult.frames {
            throw AksError.invariantViolated(
                "exported file has \(frameCount) video samples, expected \(videoResult.frames)")
        }

        if options.overwrite {
            try? fm.removeItem(at: outputURL)
        }
        try AtomicFile.rename(from: partialURL, to: outputURL)
        try AtomicFile.syncDirectory(outputURL.deletingLastPathComponent())
        outputCommitted = true

        return Result(
            outputURL: outputURL,
            durationNs: exportedDuration,
            videoFrames: videoResult.frames,
            videoSegments: videoSegments.count,
            audioFrames: audioFrames,
            silenceFramesInserted: max(0, audioFrames - coveredAudioFrames),
            warnings: warnings)
    }

    // MARK: - Video pump

    private static func pumpVideo(
        segments: [SegmentDescriptor], layout: ProjectLayout,
        box: WriterBox, progress: (@Sendable (String, Double) -> Void)?
    ) async throws -> VideoPumpResult {
        var result = VideoPumpResult(frames: 0, warnings: [])
        for (index, segment) in segments.enumerated() {
            try Task.checkCancellation()
            progress?("video", Double(index) / Double(segments.count))
            try Task.checkCancellation()
            let url = try layout.resolve(relativePath: segment.path)
            let frames = try await copyVideoSamples(
                from: url, segment: segment, into: box.videoInput, writer: box.writer)
            if let expected = segment.video?.frameCount, frames != expected {
                result.warnings.append(
                    "\(segment.path): copied \(frames) frames, descriptor says \(expected)")
            }
            result.frames += frames
        }
        box.videoInput.markAsFinished()
        progress?("video", 1.0)
        return result
    }

    /// Stream-copy one segment's compressed samples, retimed onto the project
    /// timeline. Returns the number of samples copied.
    private static func copyVideoSamples(
        from url: URL, segment: SegmentDescriptor,
        into input: AVAssetWriterInput, writer: AVAssetWriter
    ) async throws -> Int {
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw AksError.invariantViolated("\(segment.path): no video track")
        }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        output.alwaysCopiesSampleData = false
        reader.add(output)
        guard reader.startReading() else {
            throw AksError.invariantViolated(
                "\(segment.path): reader failed: \(reader.error.map { "\($0)" } ?? "unknown")")
        }

        var copied = 0
        var timeShiftNs: Int64?
        while let sample = output.copyNextSampleBuffer() {
            let pts = CMSampleBufferGetPresentationTimeStamp(sample)
            guard pts.isNumeric else { continue }
            let ptsNs = Int64(pts.seconds * 1_000_000_000)
            if timeShiftNs == nil {
                // First sample lands exactly at the segment's normalized
                // start regardless of the container's internal time origin.
                timeShiftNs = segment.normalizedStartNs - ptsNs
            }
            let shifted = try retimed(sample, byNs: timeShiftNs ?? 0)
            try await appendWhenReady(shifted, to: input, writer: writer)
            copied += CMSampleBufferGetNumSamples(sample)
        }
        if reader.status == .failed {
            throw AksError.invariantViolated(
                "\(segment.path): read failed: \(reader.error.map { "\($0)" } ?? "unknown")")
        }
        return copied
    }

    static func retimed(_ sample: CMSampleBuffer, byNs shiftNs: Int64) throws -> CMSampleBuffer {
        guard shiftNs != 0 else { return sample }
        var count = 0
        CMSampleBufferGetSampleTimingInfoArray(
            sample, entryCount: 0, arrayToFill: nil, entriesNeededOut: &count)
        var timing = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(), count: count)
        CMSampleBufferGetSampleTimingInfoArray(
            sample, entryCount: count, arrayToFill: &timing, entriesNeededOut: nil)
        let shift = CMTime(value: shiftNs, timescale: 1_000_000_000)
        for index in timing.indices {
            if timing[index].presentationTimeStamp.isNumeric {
                timing[index].presentationTimeStamp = timing[index].presentationTimeStamp + shift
            }
            if timing[index].decodeTimeStamp.isNumeric {
                timing[index].decodeTimeStamp = timing[index].decodeTimeStamp + shift
            }
        }
        var retimedOut: CMSampleBuffer?
        let status = CMSampleBufferCreateCopyWithNewTiming(
            allocator: nil, sampleBuffer: sample,
            sampleTimingEntryCount: count, sampleTimingArray: &timing,
            sampleBufferOut: &retimedOut)
        guard status == noErr, let retimedOut else {
            throw AksError.invariantViolated("retiming failed (status \(status))")
        }
        return retimedOut
    }

    // MARK: - Audio pump

    private static func pumpAudio(
        micSegments: [SegmentDescriptor], systemSegments: [SegmentDescriptor],
        layout: ProjectLayout, box: WriterBox,
        sampleRate: Double, mixChannels: Int,
        minimumEndNs: Int64, progress: (@Sendable (String, Double) -> Void)?
    ) async throws -> (frames: Int64, covered: Int64) {
        guard let audioInput = box.audioInput else { return (0, 0) }
        let micReader = micSegments.isEmpty
            ? nil
            : try AudioTimelineReader(segments: micSegments, layout: layout, sampleRate: sampleRate)
        let systemReader = systemSegments.isEmpty
            ? nil
            : try AudioTimelineReader(segments: systemSegments, layout: layout, sampleRate: sampleRate)
        let readers = [micReader, systemReader].compactMap { $0 }

        let audioEndFrame = max(
            readers.map(\.endFrame).max() ?? 0,
            Int64((Double(minimumEndNs) / 1e9 * sampleRate).rounded()))
        guard let audioFormat = makeAudioFormatDescription(
            sampleRate: sampleRate, channels: mixChannels)
        else {
            throw AksError.invariantViolated("cannot create audio format description")
        }

        let blockFrames = 24_000  // 0.5 s
        var mixBuffer = [Float](repeating: 0, count: blockFrames * mixChannels)
        var position: Int64 = 0
        var total: Int64 = 0
        while position < audioEndFrame {
            try Task.checkCancellation()
            let frames = Int(min(Int64(blockFrames), audioEndFrame - position))
            for index in 0..<(frames * mixChannels) { mixBuffer[index] = 0 }
            for reader in readers {
                var trackBuffer = [Float](repeating: 0, count: frames * reader.channels)
                try reader.read(into: &trackBuffer, frames: frames, at: position)
                for frame in 0..<frames {
                    for channel in 0..<mixChannels {
                        let sourceChannel = min(channel, reader.channels - 1)
                        mixBuffer[frame * mixChannels + channel] +=
                            trackBuffer[frame * reader.channels + sourceChannel]
                    }
                }
            }
            // Clip guard: mixing in float can exceed ±1.
            for index in 0..<(frames * mixChannels) {
                mixBuffer[index] = max(-1, min(1, mixBuffer[index]))
            }
            let sampleBuffer = try makeAudioSampleBuffer(
                samples: mixBuffer, frames: frames, channels: mixChannels,
                sampleRate: sampleRate, format: audioFormat, ptsFrames: position)
            try await appendWhenReady(sampleBuffer, to: audioInput, writer: box.writer)
            position += Int64(frames)
            total += Int64(frames)
            progress?("audio", Double(position) / Double(max(audioEndFrame, 1)))
        }
        audioInput.markAsFinished()
        let covered = readers.map(\.coveredFrames).max() ?? 0
        return (total, covered)
    }

    // MARK: - Shared plumbing

    private static func videoFormatDescription(of url: URL) async throws -> CMFormatDescription? {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            return nil
        }
        let descriptions = try await track.load(.formatDescriptions)
        return descriptions.first
    }

    static func makeAudioFormatDescription(
        sampleRate: Double, channels: Int
    ) -> CMAudioFormatDescription? {
        var asbd = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: UInt32(4 * channels),
            mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(4 * channels),
            mChannelsPerFrame: UInt32(channels),
            mBitsPerChannel: 32,
            mReserved: 0)
        var description: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(
            allocator: nil, asbd: &asbd,
            layoutSize: 0, layout: nil,
            magicCookieSize: 0, magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &description)
        return description
    }

    static func makeAudioSampleBuffer(
        samples: [Float], frames: Int, channels: Int,
        sampleRate: Double, format: CMAudioFormatDescription,
        ptsFrames: Int64
    ) throws -> CMSampleBuffer {
        let byteCount = frames * channels * 4
        var blockBuffer: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: nil, memoryBlock: nil, blockLength: byteCount,
            blockAllocator: nil, customBlockSource: nil,
            offsetToData: 0, dataLength: byteCount, flags: 0,
            blockBufferOut: &blockBuffer)
        guard status == noErr, let blockBuffer else {
            throw AksError.invariantViolated("audio block buffer failed (status \(status))")
        }
        status = samples.withUnsafeBytes { bytes in
            CMBlockBufferReplaceDataBytes(
                with: bytes.baseAddress!, blockBuffer: blockBuffer,
                offsetIntoDestination: 0, dataLength: byteCount)
        }
        guard status == noErr else {
            throw AksError.invariantViolated("audio block copy failed (status \(status))")
        }
        var sampleBuffer: CMSampleBuffer?
        status = CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: nil, dataBuffer: blockBuffer,
            formatDescription: format,
            sampleCount: frames,
            presentationTimeStamp: CMTime(
                value: ptsFrames, timescale: CMTimeScale(sampleRate)),
            packetDescriptions: nil,
            sampleBufferOut: &sampleBuffer)
        guard status == noErr, let sampleBuffer else {
            throw AksError.invariantViolated("audio sample buffer failed (status \(status))")
        }
        return sampleBuffer
    }

    static func appendWhenReady(
        _ sample: CMSampleBuffer, to input: AVAssetWriterInput, writer: AVAssetWriter
    ) async throws {
        try Task.checkCancellation()
        while !input.isReadyForMoreMediaData {
            if writer.status == .failed {
                throw AksError.invariantViolated(
                    "export writer failed: \(writer.error.map { "\($0)" } ?? "unknown")")
            }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        try Task.checkCancellation()
        guard input.append(sample) else {
            throw AksError.invariantViolated(
                "export append failed: \(writer.error.map { "\($0)" } ?? "unknown")")
        }
    }
}
