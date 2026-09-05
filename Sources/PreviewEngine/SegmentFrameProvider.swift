import AVFoundation
import CoreImage
import Foundation
import ProjectModel

/// Random-access decoded frames over a track's committed segments.
///
/// Segments are short (≤5 s) finalized files, so seeking is implemented as
/// "open the right segment and decode forward to the target" — no reliance on
/// container edit-list time mapping, and sequential playback advances one
/// sample at a time. Timeline mapping uses each segment's own descriptor:
/// timeline pts = normalizedStartNs + (file pts − first file pts).
public final class SegmentFrameProvider {
    private struct Entry {
        let descriptor: SegmentDescriptor
        let url: URL
    }

    private let entries: [Entry]
    /// When set, segments decode at (at most) this height and the frames are
    /// scaled back into source-pixel space. Geometry is unchanged — only
    /// decode quality drops — which keeps the preview==export invariant
    /// (quality may differ; geometry/timing may not) while making 4K scrubs
    /// cheap. Export passes nil and decodes at full resolution.
    private let decodeMaxHeight: Int?
    private var decodeUpscaleX: Double = 1
    private var decodeUpscaleY: Double = 1

    private var openIndex: Int?
    private var reader: AVAssetReader?
    private var output: AVAssetReaderTrackOutput?
    private var firstFilePtsNs: Int64?
    /// Latest decoded frame with timeline pts ≤ the last requested time.
    private var currentFrame: (ptsNs: Int64, image: CIImage)?
    private var nextSample: (ptsNs: Int64, image: CIImage)?

    public init(
        segments: [SegmentDescriptor], layout: ProjectLayout,
        decodeMaxHeight: Int? = nil
    ) throws {
        self.entries = try segments
            .sorted { $0.sequenceInTrack < $1.sequenceInTrack }
            .map { Entry(descriptor: $0, url: try layout.resolve(relativePath: $0.path)) }
        self.decodeMaxHeight = decodeMaxHeight
    }

    public var isEmpty: Bool { entries.isEmpty }

    public var durationNs: Int64 {
        entries.map(\.descriptor.normalizedEndNs).max() ?? 0
    }

    public var sourceSize: SIMD2<Double> {
        guard let video = entries.first?.descriptor.video else { return SIMD2(1, 1) }
        return SIMD2(Double(video.widthPx), Double(video.heightPx))
    }

    /// The frame visible at `timeNs`: the latest sample at or before it.
    /// Between segments (sparse content) the previous frame persists.
    public func frame(at timeNs: Int64) async throws -> CIImage? {
        guard !entries.isEmpty else { return nil }
        let targetIndex = segmentIndex(for: timeNs)

        // Backward seek, or a jump to a different segment behind/ahead:
        // reopen at the segment containing (or preceding) the target.
        let needsReopen: Bool
        if let openIndex {
            let movedBackward = (currentFrame?.ptsNs ?? Int64.max) > timeNs
            let farForward = timeNs - (currentFrame?.ptsNs ?? timeNs) > 2_000_000_000
            needsReopen = movedBackward || targetIndex < openIndex || farForward
        } else {
            needsReopen = true
        }
        if needsReopen {
            try await open(index: targetIndex, seekToNs: timeNs)
        }

        // Advance forward until the next sample would pass the target,
        // crossing into later segments as needed.
        while true {
            if let next = nextSample, next.ptsNs <= timeNs {
                currentFrame = next
                nextSample = try decodeNext()
                continue
            }
            if nextSample == nil {
                // Current segment exhausted; move to the next segment while
                // its content could still be at or before the target.
                if let openIndex, openIndex + 1 < entries.count,
                    entries[openIndex + 1].descriptor.normalizedStartNs <= timeNs
                {
                    try await open(index: openIndex + 1, keepCurrentFrame: true)
                    continue
                }
            }
            break
        }
        // A time before the first recorded frame (capture spin-up delay)
        // clamps to that first frame — returning nil left the editor's
        // preview spinning forever at t = 0 on such projects, and the
        // exporter emitting nothing for the head of the range.
        if currentFrame == nil, let next = nextSample {
            currentFrame = next
            nextSample = try decodeNext()
        }
        return currentFrame?.image
    }

    // MARK: - Internals

    private func segmentIndex(for timeNs: Int64) -> Int {
        var result = 0
        for (index, entry) in entries.enumerated() {
            if entry.descriptor.normalizedStartNs <= timeNs {
                result = index
            } else {
                break
            }
        }
        return result
    }

    private func open(
        index: Int, keepCurrentFrame: Bool = false, seekToNs: Int64? = nil
    ) async throws {
        reader?.cancelReading()
        reader = nil
        output = nil
        firstFilePtsNs = nil
        nextSample = nil
        if !keepCurrentFrame {
            currentFrame = nil
        }
        openIndex = index

        let entry = entries[index]
        let asset = AVURLAsset(url: entry.url)
        let newReader = try AVAssetReader(asset: asset)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw ScreenreelError.invariantViolated("\(entry.descriptor.path): no video track")
        }
        var outputSettings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        decodeUpscaleX = 1
        decodeUpscaleY = 1
        if let decodeMaxHeight,
            let video = entry.descriptor.video,
            video.heightPx > decodeMaxHeight
        {
            let scale = Double(decodeMaxHeight) / Double(video.heightPx)
            let width = max(2, Int(Double(video.widthPx) * scale) / 2 * 2)
            let height = max(2, Int(Double(video.heightPx) * scale) / 2 * 2)
            outputSettings[kCVPixelBufferWidthKey as String] = width
            outputSettings[kCVPixelBufferHeightKey as String] = height
            // Per-axis: even-rounding X and Y independently means a single
            // shared factor would stretch content ~0.5% against the
            // geometry the composer computes from sourceSize.
            decodeUpscaleX = Double(video.widthPx) / Double(width)
            decodeUpscaleY = Double(video.heightPx) / Double(height)
        }
        let newOutput = AVAssetReaderTrackOutput(track: track, outputSettings: outputSettings)
        newOutput.alwaysCopiesSampleData = false
        newReader.add(newOutput)
        // Dense keyframes (0.75 s) make mid-segment starts cheap: begin
        // decoding at most ~0.8 s before the target instead of at the
        // segment head. The reader's timeRange is ASSET-relative (each
        // segment file's timeline starts at 0 == the segment's first
        // frame), and a target past the recorded content clamps to the
        // last millisecond so the final frame still decodes.
        if let seekToNs, seekToNs > entry.descriptor.normalizedStartNs {
            let contentNs = entry.descriptor.normalizedEndNs
                - entry.descriptor.normalizedStartNs
            let relative = min(
                seekToNs - entry.descriptor.normalizedStartNs,
                max(0, contentNs - 1_000_000))
            let start = max(0, relative - 800_000_000)
            if start > 0 {
                newReader.timeRange = CMTimeRange(
                    start: CMTime(value: start, timescale: 1_000_000_000),
                    end: .positiveInfinity)
            }
        }
        guard newReader.startReading() else {
            throw ScreenreelError.invariantViolated(
                "\(entry.descriptor.path): decode failed: \(newReader.error.map { "\($0)" } ?? "unknown")")
        }
        reader = newReader
        output = newOutput
        nextSample = try decodeNext()
    }

    private func decodeNext() throws -> (ptsNs: Int64, image: CIImage)? {
        guard let output, let openIndex else { return nil }
        guard let sample = output.copyNextSampleBuffer() else {
            if reader?.status == .failed {
                throw ScreenreelError.invariantViolated(
                    "decode failed: \(reader?.error.map { "\($0)" } ?? "unknown")")
            }
            return nil
        }
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sample) else {
            return try decodeNext()
        }
        let pts = CMSampleBufferGetPresentationTimeStamp(sample)
        guard pts.isNumeric else { return try decodeNext() }
        let filePtsNs = Int64(pts.seconds * 1_000_000_000)
        if firstFilePtsNs == nil { firstFilePtsNs = filePtsNs }
        // Asset time 0 == the segment's first frame (writer contract), so
        // the mapping holds for head reads AND mid-file keyframe seeks —
        // anchoring on the first *decoded* pts broke seek mapping.
        let timelinePts = entries[openIndex].descriptor.normalizedStartNs + filePtsNs
        // Copy into an independent CIImage so the reader's buffer pool can
        // recycle without corrupting the frame we hand out.
        var image = CIImage(cvPixelBuffer: pixelBuffer)
        if decodeUpscaleX != 1 || decodeUpscaleY != 1 {
            // Back into source-pixel coordinates so composition geometry is
            // identical to a full-resolution decode.
            image = image.transformed(by: CGAffineTransform(
                scaleX: decodeUpscaleX, y: decodeUpscaleY))
        }
        return (timelinePts, image)
    }
}
