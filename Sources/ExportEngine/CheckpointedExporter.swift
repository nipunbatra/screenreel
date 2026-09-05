import AVFoundation
import CoreMedia
import CryptoKit
import Foundation
import PreviewEngine
import ProjectModel
import TimelineCore

/// Resumable styled export (EXPORT_PIPELINE.md §5-6, §11): video renders in
/// deterministic fixed-frame segments, each independently readable,
/// atomically renamed, and checkpointed with its checksum. A killed or
/// cancelled export resumes at the first missing/invalid segment. Final
/// assembly concatenates segments WITHOUT re-encoding, renders audio in one
/// continuous pass (no per-segment denoiser seams), validates a `.partial`,
/// and only then renames it into place. Raw media is never touched; the
/// job directory lives under the project's jobs/ and is removed on success.
public enum CheckpointedExporter {

    /// Spec floor is 30 s (EXPORT_PIPELINE.md §5). Tests lower it to create
    /// multi-segment jobs from small fixtures without minute-long renders.
    nonisolated(unsafe) static var segmentFloorSeconds = 30

    public struct Options: Sendable {
        public var fps: Double
        public var codec: MediaCodec
        public var bitsPerPixelPerFrame: Double
        public var outputHeight: Int?
        public var includeAudio: Bool
        public var aacBitrate: Int
        public var overwrite: Bool
        /// Segment length; the spec's 30-120 s window, clamped.
        public var segmentSeconds: Int
        public var progress: (@Sendable (String, Double) -> Void)?

        public init(
            fps: Double = 30,
            codec: MediaCodec = .hevc,
            bitsPerPixelPerFrame: Double = 0.16,
            outputHeight: Int? = nil,
            includeAudio: Bool = true,
            aacBitrate: Int = 160_000,
            overwrite: Bool = false,
            segmentSeconds: Int = 60,
            progress: (@Sendable (String, Double) -> Void)? = nil
        ) {
            self.fps = fps
            self.codec = codec
            self.bitsPerPixelPerFrame = bitsPerPixelPerFrame
            self.outputHeight = outputHeight
            self.includeAudio = includeAudio
            self.aacBitrate = aacBitrate
            self.overwrite = overwrite
            self.segmentSeconds = min(
                120, max(CheckpointedExporter.segmentFloorSeconds, segmentSeconds))
            self.progress = progress
        }
    }

    public struct Result: Sendable {
        public let outputURL: URL
        public let videoFrames: Int
        public let segmentsRendered: Int
        public let segmentsReused: Int
        public let warnings: [String]
    }

    struct Checkpoint: Codable, Equatable {
        struct Segment: Codable, Equatable {
            var index: Int
            var fileName: String
            var frames: Int
            var byteSize: Int64
            var sha256: String
        }
        var schemaVersion: Int
        var jobKey: String
        var fps: Double
        var totalFrames: Int
        var segmentFrames: Int
        var rangeStartNs: Int64
        var rangeEndNs: Int64
        var segments: [Segment]
    }

    public static func export(
        projectAt projectURL: URL,
        to outputURL: URL,
        options: Options = Options()
    ) async throws -> Result {
        let fm = FileManager.default
        if fm.fileExists(atPath: outputURL.path), !options.overwrite {
            throw AksError.ioFailed(
                operation: "export", path: outputURL.path, errno: EEXIST)
        }

        let activity = SystemActivity(.export, reason: "Checkpointed export")
        defer { activity.end() }
        guard options.fps > 0, options.fps.rounded() == options.fps else {
            throw AksError.invariantViolated(
                "checkpointed export requires an integer fps (got \(options.fps))")
        }

        let composition = try ProjectComposition(projectURL: projectURL)
        let layout = composition.layout
        let range = composition.trimmedRange
        let rangeDurationNs = range.endNs - range.startNs
        guard rangeDurationNs > 0 else {
            throw AksError.invariantViolated("trimmed range is empty")
        }
        // EXACTLY StyledExporter's frame-count formula, so segment sums
        // always reconcile with a single-file export of the same range.
        let totalFrames = max(
            1, Int((Double(rangeDurationNs) / 1e9 * options.fps).rounded(.up)))
        let segmentFrames = Int(options.fps) * options.segmentSeconds
        let segmentCount = (totalFrames + segmentFrames - 1) / segmentFrames

        // The job key freezes everything that affects the pixels: settings,
        // geometry, the edit document bytes, and the range. Any change
        // invalidates old segments wholesale (spec §5: reuse only on match).
        let jobKey = try makeJobKey(
            layout: layout, range: range, totalFrames: totalFrames,
            segmentFrames: segmentFrames, options: options)
        let jobDirectory = layout.jobsDirectory
            .appendingPathComponent("export-\(jobKey.prefix(16))")
        try fm.createDirectory(
            at: jobDirectory, withIntermediateDirectories: true)
        let checkpointURL = jobDirectory.appendingPathComponent("checkpoint.json")

        // Resume: adopt every recorded segment that still validates.
        var checkpoint = Checkpoint(
            schemaVersion: 1, jobKey: jobKey, fps: options.fps,
            totalFrames: totalFrames, segmentFrames: segmentFrames,
            rangeStartNs: range.startNs, rangeEndNs: range.endNs,
            segments: [])
        var reused = 0
        if let data = try? Data(contentsOf: checkpointURL),
            let stored = try? JSONDecoder().decode(Checkpoint.self, from: data),
            stored.jobKey == jobKey,
            stored.totalFrames == totalFrames,
            stored.segmentFrames == segmentFrames
        {
            for segment in stored.segments.sorted(by: { $0.index < $1.index }) {
                let url = jobDirectory.appendingPathComponent(segment.fileName)
                let expected = min(totalFrames, (segment.index + 1) * segmentFrames)
                    - segment.index * segmentFrames
                guard segment.frames == expected,
                    let size = try? fm.attributesOfItem(atPath: url.path)[.size]
                    as? Int64,
                    size == segment.byteSize,
                    (try? sha256(of: url)) == segment.sha256
                else {
                    try? fm.removeItem(at: url)  // damaged/short: re-render alone
                    continue
                }
                checkpoint.segments.append(segment)
                reused += 1
            }
        }

        // Render every missing segment, checkpointing after each.
        var rendered = 0
        var warnings: [String] = []
        let done = Set(checkpoint.segments.map(\.index))
        for index in 0..<segmentCount where !done.contains(index) {
            try Task.checkCancellation()
            try ensureDiskSpace(
                for: jobDirectory, segmentsLeft: segmentCount - done.count - rendered,
                renderedBytes: checkpoint.segments.reduce(0) { $0 + $1.byteSize },
                renderedSegments: checkpoint.segments.count)

            let startFrame = index * segmentFrames
            let endFrame = min(totalFrames, (index + 1) * segmentFrames)
            let segmentStartNs = range.startNs
                + Int64((Double(startFrame) / options.fps * 1e9).rounded())
            let segmentEndNs = index == segmentCount - 1
                ? range.endNs
                : range.startNs
                    + Int64((Double(endFrame) / options.fps * 1e9).rounded())
            let fileName = String(format: "seg-%04d.mp4", index)
            let segmentURL = jobDirectory.appendingPathComponent(fileName)

            let doneCount = Double(checkpoint.segments.count)
            let progressBase = doneCount / Double(segmentCount)
            let progressSpan = 1.0 / Double(segmentCount)
            let outerProgress = options.progress
            let result = try await StyledExporter.export(
                projectAt: projectURL, to: segmentURL,
                options: .init(
                    fps: options.fps,
                    codec: options.codec,
                    bitsPerPixelPerFrame: options.bitsPerPixelPerFrame,
                    outputHeight: options.outputHeight,
                    includeAudio: false,  // audio is one continuous final pass
                    overwrite: true,
                    outputRangeNs: (segmentStartNs, segmentEndNs),
                    progress: { _, fraction in
                        outerProgress?(
                            "render", progressBase + fraction * progressSpan)
                    }))
            warnings.append(contentsOf: result.warnings)
            let expectedFrames = endFrame - startFrame
            guard result.videoFrames == expectedFrames else {
                // Do NOT checkpoint a short segment: it would re-validate
                // by sha on every resume and wedge the job permanently at
                // the reconciliation guard.
                try? fm.removeItem(at: segmentURL)
                throw AksError.invariantViolated(
                    "segment \(index) rendered \(result.videoFrames) of "
                        + "\(expectedFrames) frames — a source segment in this "
                        + "range decodes no samples; run `aks validate` on the "
                        + "project")
            }

            let size = (try? fm.attributesOfItem(atPath: segmentURL.path)[.size]
                as? Int64) ?? 0
            checkpoint.segments.append(Checkpoint.Segment(
                index: index, fileName: fileName,
                frames: result.videoFrames, byteSize: size,
                sha256: try sha256(of: segmentURL)))
            checkpoint.segments.sort { $0.index < $1.index }
            try AtomicFile.writeJSON(checkpoint, to: checkpointURL)
            rendered += 1
        }

        let segmentFrameSum = checkpoint.segments.reduce(0) { $0 + $1.frames }
        guard checkpoint.segments.count == segmentCount,
            segmentFrameSum == totalFrames
        else {
            throw AksError.invariantViolated(
                "segment reconciliation failed: \(checkpoint.segments.count)/\(segmentCount) "
                    + "segments, \(segmentFrameSum)/\(totalFrames) frames")
        }

        // Final assembly: concat without re-encode + continuous audio.
        let frames = try await assemble(
            checkpoint: checkpoint, jobDirectory: jobDirectory,
            composition: composition, layout: layout,
            outputURL: outputURL, options: options, warnings: &warnings)

        // Success: the job directory has served its purpose.
        try? fm.removeItem(at: jobDirectory)
        options.progress?("render", 1.0)
        return Result(
            outputURL: outputURL, videoFrames: frames,
            segmentsRendered: rendered, segmentsReused: reused,
            warnings: warnings)
    }

    // MARK: - Final assembly

    private static func assemble(
        checkpoint: Checkpoint,
        jobDirectory: URL,
        composition: ProjectComposition,
        layout: ProjectLayout,
        outputURL: URL,
        options: Options,
        warnings: inout [String]
    ) async throws -> Int {
        let fm = FileManager.default
        let partialURL = outputURL.deletingLastPathComponent()
            .appendingPathComponent(outputURL.lastPathComponent + ".partial.mp4")
        try? fm.removeItem(at: partialURL)

        // Passthrough video input hinted with the first segment's format.
        let firstURL = jobDirectory
            .appendingPathComponent(checkpoint.segments[0].fileName)
        let firstAsset = AVURLAsset(url: firstURL)
        guard let firstTrack = try await firstAsset.loadTracks(
            withMediaType: .video).first,
            let format = try await firstTrack.load(.formatDescriptions).first
        else {
            throw AksError.invariantViolated("segment 0 has no video track")
        }

        let writer = try AVAssetWriter(outputURL: partialURL, fileType: .mp4)
        let videoInput = AVAssetWriterInput(
            mediaType: .video, outputSettings: nil, sourceFormatHint: format)
        videoInput.expectsMediaDataInRealTime = false
        writer.add(videoInput)

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
            warnings.append(
                "project has no committed audio segments; exporting silent video")
        }

        guard writer.startWriting() else {
            throw AksError.invariantViolated(
                "assembly writer failed to start: \(writer.error.map { "\($0)" } ?? "unknown")")
        }
        writer.startSession(atSourceTime: .zero)

        // Continuous audio pass (the whole range through the SAME pump as
        // the single-file exporter: one denoiser stream, no seams).
        var audioTask: Task<(Int64, Int64), Error>?
        if let audioInput {
            let box = StyledExporter.AudioPumpBox(writer: writer, input: audioInput)
            let micSegments = composition.micSegments
            let systemSegments = composition.systemSegments
            let denoise = composition.edits.micNoiseReduction
            let clipTimeline = composition.clipTimeline
            let rangeStart = checkpoint.rangeStartNs
            let rangeEnd = checkpoint.rangeEndNs
            let progress = options.progress
            audioTask = Task.detached {
                try await StyledExporter.pumpTrimmedAudio(
                    micSegments: micSegments, systemSegments: systemSegments,
                    layout: layout, box: box,
                    sampleRate: sampleRate, mixChannels: mixChannels,
                    rangeStartNs: rangeStart, rangeEndNs: rangeEnd,
                    clipTimeline: clipTimeline,
                    denoiseMic: denoise,
                    progress: progress)
            }
        }

        // Sequential passthrough concat, each segment retimed to its
        // global offset.
        var appendedSamples = 0
        do {
            for segment in checkpoint.segments {
                try Task.checkCancellation()
                let url = jobDirectory.appendingPathComponent(segment.fileName)
                let asset = AVURLAsset(url: url)
                guard let track = try await asset.loadTracks(
                    withMediaType: .video).first
                else {
                    throw AksError.invariantViolated(
                        "\(segment.fileName) has no video track")
                }
                let reader = try AVAssetReader(asset: asset)
                let output = AVAssetReaderTrackOutput(
                    track: track, outputSettings: nil)
                output.alwaysCopiesSampleData = false
                reader.add(output)
                guard reader.startReading() else {
                    throw AksError.invariantViolated(
                        "cannot read \(segment.fileName): \(reader.error.map { "\($0)" } ?? "unknown")")
                }
                let shiftNs = segmentOffsetNs(
                    segment.index, checkpoint: checkpoint)
                while let sample = output.copyNextSampleBuffer() {
                    while !videoInput.isReadyForMoreMediaData {
                        if writer.status == .failed {
                            throw AksError.invariantViolated(
                                "assembly writer failed: \(writer.error.map { "\($0)" } ?? "unknown")")
                        }
                        try await Task.sleep(nanoseconds: 2_000_000)
                    }
                    let shifted = try SegmentAssembler.retimed(sample, byNs: shiftNs)
                    guard videoInput.append(shifted) else {
                        throw AksError.invariantViolated(
                            "assembly append failed: \(writer.error.map { "\($0)" } ?? "unknown")")
                    }
                    appendedSamples += CMSampleBufferGetNumSamples(sample)
                }
                if reader.status == .failed {
                    throw AksError.invariantViolated(
                        "reading \(segment.fileName) failed: \(reader.error.map { "\($0)" } ?? "unknown")")
                }
            }
        } catch {
            audioTask?.cancel()
            _ = try? await audioTask?.value
            writer.cancelWriting()
            try? fm.removeItem(at: partialURL)
            throw error
        }
        videoInput.markAsFinished()
        if let audioTask {
            do {
                _ = try await audioTask.value
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
                "assembly finalize failed: \(writer.error.map { "\($0)" } ?? "unknown")")
        }

        // Spec §12 validation before the file may exist at its final name.
        let probe = await CaptureCoreInspector().probe(url: partialURL)
        guard probe.decodable, probe.issues.isEmpty else {
            try? fm.removeItem(at: partialURL)
            throw AksError.invariantViolated(
                "assembled file failed validation: \(probe.issues.joined(separator: "; "))")
        }
        if let count = probe.frameCount, count != appendedSamples {
            try? fm.removeItem(at: partialURL)
            throw AksError.invariantViolated(
                "assembled file has \(count) frames, expected \(appendedSamples)")
        }
        if options.overwrite {
            try? fm.removeItem(at: outputURL)
        }
        try AtomicFile.rename(from: partialURL, to: outputURL)
        try AtomicFile.syncDirectory(outputURL.deletingLastPathComponent())
        return appendedSamples
    }

    private static func segmentOffsetNs(_ index: Int, checkpoint: Checkpoint) -> Int64 {
        Int64((Double(index * checkpoint.segmentFrames) / checkpoint.fps * 1e9)
            .rounded())
    }

    // MARK: - Job identity, hashing, disk

    private static func makeJobKey(
        layout: ProjectLayout,
        range: (startNs: Int64, endNs: Int64),
        totalFrames: Int,
        segmentFrames: Int,
        options: Options
    ) throws -> String {
        var hasher = SHA256()
        let editsURL = layout.editsDirectory
            .appendingPathComponent("timeline.json")
        if let editBytes = try? Data(contentsOf: editsURL) {
            hasher.update(data: editBytes)
        }
        let settings = [
            "v1", "\(options.fps)", options.codec.rawValue,
            "\(options.bitsPerPixelPerFrame)",
            "\(options.outputHeight.map(String.init) ?? "native")",
            "\(range.startNs)", "\(range.endNs)",
            "\(totalFrames)", "\(segmentFrames)",
        ].joined(separator: "|")
        hasher.update(data: Data(settings.utf8))
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Spec §8: recheck space at segment boundaries; refuse before starting
    /// a segment that could strand the disk, never corrupt committed work.
    private static func ensureDiskSpace(
        for jobDirectory: URL, segmentsLeft: Int,
        renderedBytes: Int64, renderedSegments: Int
    ) throws {
        let perSegment = renderedSegments > 0
            ? renderedBytes / Int64(renderedSegments)
            : 512 << 20  // conservative first-segment guess: 512 MB
        let needed = Double(perSegment * Int64(max(1, segmentsLeft))) * 1.25
        let values = try? jobDirectory.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        guard let free = values?.volumeAvailableCapacityForImportantUsage,
            Double(free) > needed
        else {
            let freeBytes = values?.volumeAvailableCapacityForImportantUsage ?? 0
            throw AksError.ioFailed(
                operation: "export needs ~\(Int(needed) >> 20) MB free, has \(Int(freeBytes) >> 20) MB — "
                    + "committed segments are preserved; free space and re-run to resume",
                path: jobDirectory.path, errno: ENOSPC)
        }
    }
}
