import AVFoundation
import CoreVideo
import Foundation
import ProjectModel
import Synchronization
import VideoToolbox

/// Lock-free mirrors of a writer's frame counters. Observers (the session
/// heartbeat's perf trace, the stop summary) read these without queueing
/// behind an in-flight append on the writer actor — the encoder path never
/// waits on a reader.
public final class WriterCounters: Sendable {
    private let frames = Atomic<Int>(0)
    private let dropped = Atomic<Int>(0)

    public var totalFrames: Int { frames.load(ordering: .relaxed) }
    public var droppedFrames: Int { dropped.load(ordering: .relaxed) }

    func noteFrame() { frames.add(1, ordering: .relaxed) }
    func noteDrop() { dropped.add(1, ordering: .relaxed) }
}

/// Per-track encoding settings for a segmented video writer, so screen and
/// camera tracks share one implementation.
public struct VideoWriterSettings: Sendable {
    public var trackType: TrackType
    public var displayID: Int?
    public var widthPx: Int
    public var heightPx: Int
    public var nominalFrameRate: Double
    public var codec: MediaCodec
    public var bitsPerPixelPerFrame: Double
    public var segmentDurationNs: Int64

    public init(
        trackType: TrackType, displayID: Int?, widthPx: Int, heightPx: Int,
        nominalFrameRate: Double, codec: MediaCodec,
        bitsPerPixelPerFrame: Double, segmentDurationNs: Int64
    ) {
        precondition(trackType == .screen || trackType == .camera)
        self.trackType = trackType
        self.displayID = displayID
        self.widthPx = widthPx
        self.heightPx = heightPx
        self.nominalFrameRate = nominalFrameRate
        self.codec = codec
        self.bitsPerPixelPerFrame = bitsPerPixelPerFrame
        self.segmentDurationNs = segmentDurationNs
    }

    public static func screen(from configuration: CaptureConfiguration) -> VideoWriterSettings {
        VideoWriterSettings(
            trackType: .screen, displayID: configuration.displayID,
            widthPx: configuration.widthPx, heightPx: configuration.heightPx,
            nominalFrameRate: configuration.nominalFrameRate,
            codec: configuration.videoCodec,
            bitsPerPixelPerFrame: configuration.bitsPerPixelPerFrame,
            segmentDurationNs: configuration.segmentDurationNs)
    }

    /// Camera settings; pass 0×0 to size the encoder from the first
    /// delivered frame — the only reliable source, since a preview session
    /// may have reconfigured the device's activeFormat.
    public static func camera(
        widthPx: Int, heightPx: Int, frameRate: Double, segmentDurationNs: Int64
    ) -> VideoWriterSettings {
        VideoWriterSettings(
            trackType: .camera, displayID: nil,
            widthPx: widthPx, heightPx: heightPx,
            nominalFrameRate: frameRate, codec: .hevc,
            // Camera content moves everywhere; more bits per pixel than
            // mostly-static screens.
            bitsPerPixelPerFrame: 0.2,
            segmentDurationNs: segmentDurationNs)
    }
}

/// Segmented raw video writer (screen or camera): short finalized QuickTime
/// segments (ADR 0002), one `AVAssetWriter` per segment, rolled at the
/// configured boundary.
/// The next segment opens immediately so frames are never dropped while the
/// previous writer finalizes in the background; commits stay ordered through
/// a chained task.
public actor VideoSegmentWriter {
    public typealias CommitHandler = @Sendable (SegmentDescriptor) async throws -> Void
    public typealias OpenHandler = @Sendable (_ path: String, _ sequenceInTrack: Int) async throws -> Void
    public typealias FaultHandler = @Sendable (_ kind: String, _ message: String) async -> Void

    private let trackID: UUID
    private let settings: VideoWriterSettings
    /// Actual encode dimensions: settings dims, or (for 0×0 settings) the
    /// first frame's own dimensions.
    private var resolvedWidthPx = 0
    private var resolvedHeightPx = 0
    private let layout: ProjectLayout
    private let directory: URL
    private let onOpen: OpenHandler
    private let onCommit: CommitHandler
    private let onFault: FaultHandler

    /// Pre-warmed successor writer: AVAssetWriter takes ~100–160 ms to be
    /// ready for its first append (VideoToolbox spin-up), which at every
    /// segment boundary overflowed the bounded handoff and dropped frames.
    /// The next segment's writer is created mid-segment so rotation swaps
    /// to an already-warm encoder.
    private struct Standby {
        let writer: AVAssetWriter
        let input: AVAssetWriterInput
        let adaptor: AVAssetWriterInputPixelBufferAdaptor
        let partialURL: URL
        let finalURL: URL
        let sequence: Int
    }
    private var standby: Standby?

    /// Reference type so a rotated segment can be handed to the finalize
    /// chain as a whole; ownership transfers at rotation and the actor never
    /// touches it again (hence `@unchecked Sendable`).
    private final class OpenSegment: @unchecked Sendable {
        let writer: AVAssetWriter
        let input: AVAssetWriterInput
        let adaptor: AVAssetWriterInputPixelBufferAdaptor
        let partialURL: URL
        let finalURL: URL
        let sequenceInTrack: Int
        let startPtsNs: Int64
        let startSourceNs: Int64
        /// Writer-lifetime drop total when this segment opened; the segment's
        /// own drop count is the delta at rotation.
        let droppedAtOpen: Int
        var lastPtsNs: Int64
        var lastSourceNs: Int64
        var frameCount: Int
        /// `segmentOpened` is journaled only after the first frame lands, so
        /// a segment that never receives a frame leaves no journal trace.
        var openJournaled: Bool
        let discontinuityBefore: Bool

        init(
            writer: AVAssetWriter, input: AVAssetWriterInput,
            adaptor: AVAssetWriterInputPixelBufferAdaptor,
            partialURL: URL, finalURL: URL, sequenceInTrack: Int,
            startPtsNs: Int64, startSourceNs: Int64,
            droppedAtOpen: Int, discontinuityBefore: Bool
        ) {
            self.writer = writer
            self.input = input
            self.adaptor = adaptor
            self.partialURL = partialURL
            self.finalURL = finalURL
            self.sequenceInTrack = sequenceInTrack
            self.startPtsNs = startPtsNs
            self.startSourceNs = startSourceNs
            self.droppedAtOpen = droppedAtOpen
            self.lastPtsNs = startPtsNs
            self.lastSourceNs = startSourceNs
            self.frameCount = 0
            self.openJournaled = false
            self.discontinuityBefore = discontinuityBefore
        }
    }

    private var current: OpenSegment?
    private var nextSequence = 1
    private var finalizeChain: Task<Void, Never> = Task {}
    private var pendingDiscontinuity = false
    /// Readable from any context without awaiting the actor.
    public nonisolated let counters = WriterCounters()
    public var droppedFrames: Int { counters.droppedFrames }
    public var totalFrames: Int { counters.totalFrames }
    private var frameDurationNs: Int64 {
        Int64(1_000_000_000 / settings.nominalFrameRate)
    }

    public init(
        trackID: UUID,
        settings: VideoWriterSettings,
        layout: ProjectLayout,
        onOpen: @escaping OpenHandler,
        onCommit: @escaping CommitHandler,
        onFault: @escaping FaultHandler
    ) {
        self.trackID = trackID
        self.settings = settings
        self.layout = layout
        self.directory = layout.mediaDirectory(for: settings.trackType)
        self.onOpen = onOpen
        self.onCommit = onCommit
        self.onFault = onFault
    }

    public func append(_ frame: VideoFrame) async throws {
        if let segment = current, frame.ptsNs >= segment.startPtsNs + settings.segmentDurationNs {
            rotate()
        }
        if current == nil {
            if resolvedWidthPx == 0 {
                resolvedWidthPx = settings.widthPx > 0
                    ? settings.widthPx : CVPixelBufferGetWidth(frame.pixelBuffer) / 2 * 2
                resolvedHeightPx = settings.heightPx > 0
                    ? settings.heightPx : CVPixelBufferGetHeight(frame.pixelBuffer) / 2 * 2
            }
            try open(startPtsNs: frame.ptsNs, startSourceNs: frame.sourceNs)
        }
        guard let segment = current else { return }

        // Non-advancing timestamps (SCK occasionally repeats a PTS around
        // display reconfiguration) would fail the AVAssetWriter append and
        // kill the whole recording; a repeated frame carries no new image,
        // so skip it and count it.
        if segment.frameCount > 0, frame.ptsNs <= segment.lastPtsNs {
            counters.noteDrop()
            return
        }

        // This actor is decoupled from the capture callback by a bounded
        // stream, so it may briefly wait for encoder readiness. Sustained
        // back-pressure surfaces as counted drops here and at the stream,
        // never as hidden loss (ACCEPTANCE_TESTS §2 capture integrity).
        var waitedNs: UInt64 = 0
        while !segment.input.isReadyForMoreMediaData, waitedNs < 500_000_000 {
            try await Task.sleep(nanoseconds: 2_000_000)
            waitedNs += 2_000_000
        }
        // The sleep suspends this actor: markDiscontinuity() may have rotated
        // this segment into the finalize chain meanwhile. Never touch a
        // rotated segment again — count the frame as dropped instead.
        guard current === segment else {
            counters.noteDrop()
            return
        }
        guard segment.input.isReadyForMoreMediaData else {
            counters.noteDrop()
            if droppedFrames == 1 || droppedFrames % 30 == 0 {
                await onFault("video.framesDropped", "encoder back-pressure dropped \(droppedFrames) frame(s) so far")
            }
            return
        }
        let pts = CMTime(value: frame.ptsNs, timescale: 1_000_000_000)
        let appended: Bool
        if let retimed = Self.retimed(frame.sampleBuffer, to: pts) {
            // Zero-copy: the capture's own buffer goes straight to the
            // encoder with only its timestamp rewritten.
            appended = segment.input.append(retimed)
        } else {
            appended = segment.adaptor.append(frame.pixelBuffer, withPresentationTime: pts)
        }
        guard appended else {
            let status = segment.writer.status
            let error = segment.writer.error.map { "\($0)" } ?? "status \(status.rawValue)"
            throw ScreenreelError.invariantViolated("AVAssetWriter append failed: \(error)")
        }
        segment.lastPtsNs = frame.ptsNs
        segment.lastSourceNs = frame.sourceNs
        segment.frameCount += 1

        // Warm the next segment's encoder once this one is half done, so
        // rotation never stalls on VideoToolbox spin-up.
        if standby == nil,
            frame.ptsNs - segment.startPtsNs > settings.segmentDurationNs / 2
        {
            standby = try? makeWriterStack(sequence: nextSequence)
        }
        counters.noteFrame()

        // Journal segmentOpened after the first frame lands so empty
        // segments leave no trace; ordering before segmentCommitted holds.
        if !segment.openJournaled {
            segment.openJournaled = true
            try await onOpen(layout.relativePath(of: segment.finalURL), segment.sequenceInTrack)
        }
    }

    /// Warm known-size screen encoders before the source delivers frames.
    /// No segment is journaled until a real frame is appended. Camera
    /// dimensions are learned from its first frame, so it skips this step.
    public func prepare() throws {
        guard current == nil, standby == nil,
            settings.widthPx > 0, settings.heightPx > 0
        else { return }
        resolvedWidthPx = settings.widthPx
        resolvedHeightPx = settings.heightPx
        standby = try makeWriterStack(sequence: nextSequence)
    }

    /// Close the open tail segment and wait for every commit to finish.
    public func finish() async throws {
        rotate()
        if let stale = standby {
            stale.writer.cancelWriting()
            try? FileManager.default.removeItem(at: stale.partialURL)
            standby = nil
        }
        await finalizeChain.value
    }

    /// Called on resume (or any known source gap): close the current segment
    /// and mark the next one `discontinuityBefore`. A screen with no changes
    /// legitimately delivers no frames, so timestamp gaps alone are never
    /// treated as discontinuities — only explicit signals are.
    public func markDiscontinuity() {
        rotate()
        pendingDiscontinuity = true
    }

    /// A copy of `sample` carrying only a new presentation time (the
    /// session-normalized clock); nil when there is no buffer to reuse.
    private static func retimed(_ sample: CMSampleBuffer?, to pts: CMTime) -> CMSampleBuffer? {
        guard let sample else { return nil }
        var timing = CMSampleTimingInfo(
            duration: .invalid, presentationTimeStamp: pts, decodeTimeStamp: .invalid)
        var retimed: CMSampleBuffer?
        let status = CMSampleBufferCreateCopyWithNewTiming(
            allocator: kCFAllocatorDefault, sampleBuffer: sample,
            sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleBufferOut: &retimed)
        return status == noErr ? retimed : nil
    }

    // MARK: - Segment lifecycle

    /// Create (and start warming) the writer stack for `sequence`.
    private func makeWriterStack(sequence: Int) throws -> Standby {
        let fileName = ProjectLayout.segmentFileName(
            type: settings.trackType, displayID: settings.displayID, sequence: sequence)
        let finalURL = directory.appendingPathComponent(fileName)
        let partialURL = directory.appendingPathComponent(fileName + ProjectLayout.partialSuffix)
        try? FileManager.default.removeItem(at: partialURL)

        let writer = try AVAssetWriter(outputURL: partialURL, fileType: .mov)
        let codec: AVVideoCodecType = settings.codec == .h264 ? .h264 : .hevc
        let bitrate = Double(resolvedWidthPx * resolvedHeightPx)
            * settings.nominalFrameRate * settings.bitsPerPixelPerFrame
        var compression: [String: Any] = [
            AVVideoAverageBitRateKey: Int(bitrate),
            AVVideoExpectedSourceFrameRateKey: settings.nominalFrameRate,
            AVVideoAllowFrameReorderingKey: false,
            // Dense keyframes make backward scrubbing ~5× cheaper (decode
            // restarts at the nearest keyframe); screen content compresses
            // so well that the size cost is small.
            AVVideoMaxKeyFrameIntervalDurationKey: 0.75,
        ]
        if settings.codec == .h264 {
            compression[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel
        }
        let outputSettings: [String: Any] = [
            AVVideoCodecKey: codec,
            // Recording must never quietly fall back to a CPU encoder.
            // At Retina resolutions that can monopolize the whole Mac.
            AVVideoEncoderSpecificationKey: [
                kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder as String: true
            ],
            AVVideoWidthKey: resolvedWidthPx,
            AVVideoHeightKey: resolvedHeightPx,
            AVVideoCompressionPropertiesKey: compression,
            // Explicit BT.709 tagging: untagged screen video makes players
            // guess the transfer function and wash the colors out.
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: outputSettings)
        input.expectsMediaDataInRealTime = true
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input, sourcePixelBufferAttributes: nil)
        guard writer.canAdd(input) else {
            throw ScreenreelError.invariantViolated("AVAssetWriter rejected video input settings")
        }
        writer.add(input)
        guard writer.startWriting() else {
            let error = writer.error.map { "\($0)" } ?? "unknown"
            throw ScreenreelError.invariantViolated(
                "Hardware \(settings.codec.rawValue) recording encoder could not start at "
                    + "\(resolvedWidthPx)×\(resolvedHeightPx): \(error). "
                    + "Close other recording/export apps or choose a smaller capture area and retry.")
        }
        return Standby(
            writer: writer, input: input, adaptor: adaptor,
            partialURL: partialURL, finalURL: finalURL, sequence: sequence)
    }

    private func open(startPtsNs: Int64, startSourceNs: Int64) throws {
        let sequence = nextSequence
        nextSequence += 1
        let stack: Standby
        if let ready = standby, ready.sequence == sequence {
            stack = ready
            standby = nil
        } else {
            // A stale standby (sequence drifted) is discarded cleanly.
            if let stale = standby {
                stale.writer.cancelWriting()
                try? FileManager.default.removeItem(at: stale.partialURL)
                standby = nil
            }
            stack = try makeWriterStack(sequence: sequence)
        }
        stack.writer.startSession(
            atSourceTime: CMTime(value: startPtsNs, timescale: 1_000_000_000))

        current = OpenSegment(
            writer: stack.writer,
            input: stack.input,
            adaptor: stack.adaptor,
            partialURL: stack.partialURL,
            finalURL: stack.finalURL,
            sequenceInTrack: stack.sequence,
            startPtsNs: startPtsNs,
            startSourceNs: startSourceNs,
            droppedAtOpen: droppedFrames,
            discontinuityBefore: pendingDiscontinuity)
        pendingDiscontinuity = false
    }

    /// Detach the current segment and finalize it behind the chain; the next
    /// `append` opens a fresh segment immediately.
    private func rotate() {
        guard let segment = current else { return }
        current = nil
        let dropped = droppedFrames - segment.droppedAtOpen
        var settings = self.settings
        settings.widthPx = resolvedWidthPx
        settings.heightPx = resolvedHeightPx
        let layout = self.layout
        let directory = self.directory
        let frameDuration = frameDurationNs
        let trackID = self.trackID
        let onCommit = self.onCommit
        let onFault = self.onFault
        let previous = finalizeChain
        finalizeChain = Task {
            await previous.value
            do {
                try await Self.finalize(
                    segment: segment, trackID: trackID, settings: settings,
                    layout: layout, directory: directory, frameDurationNs: frameDuration,
                    droppedInSegment: dropped, onCommit: onCommit)
            } catch {
                await onFault("video.segmentFinalizeFailed", "\(error)")
            }
        }
    }

    private static func finalize(
        segment: OpenSegment, trackID: UUID, settings: VideoWriterSettings,
        layout: ProjectLayout, directory: URL, frameDurationNs: Int64,
        droppedInSegment: Int, onCommit: CommitHandler
    ) async throws {
        guard segment.frameCount > 0 else {
            segment.writer.cancelWriting()
            try? FileManager.default.removeItem(at: segment.partialURL)
            return
        }
        segment.input.markAsFinished()
        await segment.writer.finishWriting()
        guard segment.writer.status == .completed else {
            let error = segment.writer.error.map { "\($0)" } ?? "status \(segment.writer.status.rawValue)"
            throw ScreenreelError.invariantViolated("segment finalization failed: \(error)")
        }

        // Flush file contents to stable storage before the rename.
        let handle = try FileHandle(forWritingTo: segment.partialURL)
        try AtomicFile.sync(fileDescriptor: handle.fileDescriptor, path: segment.partialURL.path)
        try handle.close()

        // Basic decode inspection on the finalized container. AVURLAsset
        // infers type from the extension, so probe through a temporary
        // hard link carrying `.mov`.
        let inspectURL = segment.partialURL.deletingPathExtension()
            .appendingPathExtension("inspect.mov")
        try? FileManager.default.removeItem(at: inspectURL)
        try FileManager.default.linkItem(at: segment.partialURL, to: inspectURL)
        defer { try? FileManager.default.removeItem(at: inspectURL) }
        let probe = await AVMediaInspector().probe(url: inspectURL, container: .mov)
        guard probe.decodable else {
            throw ScreenreelError.invariantViolated(
                "segment failed decode inspection: \(probe.issues.joined(separator: "; "))")
        }

        let size = ((try? FileManager.default.attributesOfItem(
            atPath: segment.partialURL.path)[.size] as? Int64) ?? nil) ?? 0
        let sha = try Hashing.sha256HexOfFile(at: segment.partialURL)
        try AtomicFile.rename(from: segment.partialURL, to: segment.finalURL)
        try AtomicFile.syncDirectory(directory)

        let endPts = segment.lastPtsNs + frameDurationNs
        let descriptor = SegmentDescriptor(
            trackID: trackID,
            trackType: settings.trackType,
            path: layout.relativePath(of: segment.finalURL),
            sequenceInTrack: segment.sequenceInTrack,
            container: .mov,
            codec: settings.codec,
            video: VideoFormatInfo(
                widthPx: settings.widthPx,
                heightPx: settings.heightPx,
                nominalFrameRate: settings.nominalFrameRate,
                frameCount: segment.frameCount),
            sourceStartNs: segment.startSourceNs,
            sourceEndNs: segment.lastSourceNs + frameDurationNs,
            normalizedStartNs: segment.startPtsNs,
            normalizedEndNs: endPts,
            byteSize: size,
            sha256: sha,
            droppedFrames: droppedInSegment > 0 ? droppedInSegment : nil,
            discontinuityBefore: segment.discontinuityBefore ? true : nil,
            commitSequence: 0)  // assigned by the session when journaled
        try await onCommit(descriptor)
    }
}
