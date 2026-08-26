import Foundation
import ProjectModel

/// Segmented CAF audio writer. Rolls a new segment at the configured
/// boundary, and closes/commits each finished segment through the atomic
/// `.partial` → fsync → rename → journal protocol (`docs/PROJECT_FORMAT.md`
/// §6). A mid-stream timestamp jump closes the current segment and marks the
/// next with `discontinuityBefore` — gaps are explicit, never stretched
/// (`docs/AUDIO_PIPELINE.md` §3).
public actor AudioSegmentWriter {
    public typealias CommitHandler = @Sendable (SegmentDescriptor) async throws -> Void
    public typealias OpenHandler = @Sendable (_ path: String, _ sequenceInTrack: Int) async throws -> Void
    public typealias FaultHandler = @Sendable (_ kind: String, _ message: String) async -> Void

    private let trackID: UUID
    private let trackType: TrackType
    private let directory: URL
    private let layout: ProjectLayout
    private let sampleRate: Double
    private let channels: Int
    private let segmentDurationNs: Int64
    private let onOpen: OpenHandler
    private let onCommit: CommitHandler
    private let onFault: FaultHandler

    /// Tolerated deviation between expected and actual chunk start before a
    /// gap is declared. 20 ms mirrors the drift budget.
    private let gapToleranceNs: Int64 = 20_000_000

    // MARK: Device-rate observation

    /// Rates a lying device is snapped to when stamping descriptors; a
    /// device that misreports its rate does so between members of this set
    /// (the classic AirPods 44.1/48 k confusion), never to arbitrary values.
    private static let standardRates: [Double] = [
        8_000, 16_000, 22_050, 24_000, 44_100, 48_000, 88_200, 96_000,
    ]
    /// An observation window must span this much delivered audio before the
    /// device's rate is judged.
    private let rateWindowMinimumNs: Int64 = 2_000_000_000
    /// Observed-vs-declared deviation above this is a device rate lie.
    private let rateLieTolerance = 0.02
    /// Sub-lie clock-drift gates: both must trip before the one fault. The
    /// map's drift row targets ±0.5 % device clocks; gating the relative
    /// side at 1 000 ppm keeps classic sub-half-percent offenders (47.8 k
    /// against a declared 48 k) visible once they cost >250 ms of sync.
    private let driftMinimumRatio = 0.001
    private let driftMinimumNs: Int64 = 250_000_000

    private struct RateWindow {
        var anchorPtsNs: Int64
        /// Frames of every chunk delivered in [anchor, previous chunk] —
        /// exactly the audio the span anchor→current pts claims to cover.
        var frames: Int
    }
    private var rateWindow: RateWindow?
    private var previousChunk: (ptsNs: Int64, frames: Int)?
    /// Latched once a lie is confirmed; committed descriptors then carry
    /// this truthful rate. Raw CAF bytes are never rewritten.
    private var observedStandardRate: Double?
    private var rateFaultReported = false
    /// Whole-track clock-drift accumulation over gap-free deltas only.
    private var driftSpanNs: Int64 = 0
    private var driftFrames: Int = 0
    private var driftFaultReported = false

    private struct OpenSegment {
        var writer: CAFWriter
        var partialURL: URL
        var finalURL: URL
        var sequenceInTrack: Int
        var startPtsNs: Int64
        var startSourceNs: Int64
        var discontinuityBefore: Bool
    }

    private var current: OpenSegment?
    private var nextSequence = 1
    private var pendingDiscontinuity = false
    public private(set) var lastChunkPtsNs: Int64?
    public private(set) var totalFrames: Int = 0

    public init(
        trackID: UUID,
        trackType: TrackType,
        layout: ProjectLayout,
        sampleRate: Double,
        channels: Int,
        segmentDurationNs: Int64,
        onOpen: @escaping OpenHandler,
        onCommit: @escaping CommitHandler,
        onFault: @escaping FaultHandler = { _, _ in }
    ) {
        precondition(trackType == .microphone || trackType == .systemAudio)
        self.trackID = trackID
        self.trackType = trackType
        self.directory = layout.mediaDirectory(for: trackType)
        self.layout = layout
        self.sampleRate = sampleRate
        self.channels = channels
        self.segmentDurationNs = segmentDurationNs
        self.onOpen = onOpen
        self.onCommit = onCommit
        self.onFault = onFault
    }

    public func append(_ chunk: AudioChunk) async throws {
        // Adapt channel count when the device layout differs from the track
        // configuration (downmix by average, upmix by duplication).
        let chunk = chunk.channels == channels ? chunk : chunk.adapted(toChannels: channels)

        await observeDeviceRate(of: chunk)

        // Gap detection against the expected continuation point.
        if let segment = current {
            let expected = segment.startPtsNs
                + Int64((Double(framesInCurrent()) / sampleRate) * 1_000_000_000)
            if abs(chunk.ptsNs - expected) > gapToleranceNs {
                try await closeCurrent(endPtsNs: expected, endSourceNs: segment.startSourceNs + (expected - segment.startPtsNs))
                pendingDiscontinuity = true
            }
        }

        if current == nil {
            try await open(startPtsNs: chunk.ptsNs, startSourceNs: chunk.sourceNs)
        }
        guard let segment = current else { return }

        try segment.writer.append(samples: chunk.samples)
        totalFrames += chunk.frameCount
        lastChunkPtsNs = chunk.ptsNs

        let elapsed = chunk.ptsNs - segment.startPtsNs
            + Int64((Double(chunk.frameCount) / sampleRate) * 1_000_000_000)
        if elapsed >= segmentDurationNs {
            let endPts = segment.startPtsNs
                + Int64((Double(framesInCurrent()) / sampleRate) * 1_000_000_000)
            try await closeCurrent(
                endPtsNs: endPts,
                endSourceNs: segment.startSourceNs + (endPts - segment.startPtsNs))
        }
    }

    /// Close and commit the open tail segment.
    public func finish() async throws {
        if let segment = current {
            let endPts = segment.startPtsNs
                + Int64((Double(framesInCurrent()) / sampleRate) * 1_000_000_000)
            try await closeCurrent(
                endPtsNs: endPts,
                endSourceNs: segment.startSourceNs + (endPts - segment.startPtsNs))
        }
    }

    // MARK: - Device-rate observation

    /// Compare delivered frames against the pts span they claim to cover.
    /// A device whose callback cadence belongs to a different rate than it
    /// declares is detected within ~2 s of audio, faulted once through the
    /// session's journal path, and every descriptor committed afterwards is
    /// stamped with the observed standard rate so duration math downstream
    /// stays truthful. Smaller sustained deviations accumulate into one
    /// whole-track clock-drift fault. Raw bytes stay untouched either way.
    private func observeDeviceRate(of chunk: AudioChunk) async {
        defer { previousChunk = (chunk.ptsNs, chunk.frameCount) }
        guard let previous = previousChunk else {
            rateWindow = RateWindow(anchorPtsNs: chunk.ptsNs, frames: chunk.frameCount)
            return
        }
        let deltaNs = chunk.ptsNs - previous.ptsNs
        let predictedNs = Double(previous.frames) / sampleRate * 1e9
        let ratio = Double(deltaNs) / predictedNs

        // Whole-track drift: only near-nominal deltas accumulate, so real
        // gaps and outright rate lies can never masquerade as drift.
        if deltaNs > 0, ratio > 0.75, ratio < 1.25 {
            driftSpanNs += deltaNs
            driftFrames += previous.frames
            let declaredNs = Double(driftFrames) / sampleRate * 1e9
            let driftNs = Double(driftSpanNs) - declaredNs
            if !driftFaultReported, observedStandardRate == nil,
                abs(driftNs) > Double(driftMinimumNs),
                abs(driftNs) / Double(driftSpanNs) > driftMinimumRatio
            {
                driftFaultReported = true
                let ppm = driftNs / Double(driftSpanNs) * 1_000_000
                let observed = Double(driftFrames) / (Double(driftSpanNs) / 1e9)
                await onFault(
                    "audio.clockDrift",
                    "\(trackType.rawValue) device clock drifts \(Int(ppm.rounded())) ppm "
                        + "from the declared \(Int(sampleRate)) Hz "
                        + "(observed ≈ \(Int(observed.rounded())) Hz over \(driftSpanNs / 1_000_000_000) s)")
            }
        }

        // Rate-lie window. The stamp freezes on first detection.
        guard observedStandardRate == nil else { return }
        // Implausible deltas (a stall/hole, not any standard-rate lie)
        // restart the window at this chunk instead of polluting it.
        guard deltaNs > 0, ratio < 12.5, ratio > 0.08 else {
            rateWindow = RateWindow(anchorPtsNs: chunk.ptsNs, frames: chunk.frameCount)
            return
        }
        guard var window = rateWindow else {
            rateWindow = RateWindow(anchorPtsNs: chunk.ptsNs, frames: chunk.frameCount)
            return
        }
        let spanNs = chunk.ptsNs - window.anchorPtsNs
        if spanNs > 200_000_000, window.frames > previous.frames {
            // Consistency gate: a lying device scales EVERY delta by the
            // same factor; one delta that disagrees with the window's own
            // average is a stall or dropout — restart, don't judge.
            let windowRate = Double(window.frames) / (Double(spanNs) / 1e9)
            let instantaneous = Double(previous.frames) / (Double(deltaNs) / 1e9)
            if abs(instantaneous - windowRate) > 0.3 * windowRate {
                rateWindow = RateWindow(anchorPtsNs: chunk.ptsNs, frames: chunk.frameCount)
                return
            }
        }
        if spanNs >= rateWindowMinimumNs {
            let observed = Double(window.frames) / (Double(spanNs) / 1e9)
            if abs(observed - sampleRate) / sampleRate > rateLieTolerance {
                let standard = Self.standardRates.min {
                    abs($0 - observed) < abs($1 - observed)
                } ?? sampleRate
                observedStandardRate = standard
                if !rateFaultReported {
                    rateFaultReported = true
                    await onFault(
                        "audio.rateMismatch",
                        "\(trackType.rawValue) declared \(Int(sampleRate)) Hz but delivers "
                            + "≈ \(Int(observed.rounded())) Hz; committed segments are stamped "
                            + "\(Int(standard)) Hz so durations stay truthful")
                }
                return
            }
            // Healthy ≥2 s window: restart it so a mid-stream device swap
            // is still caught within the next window.
            rateWindow = RateWindow(anchorPtsNs: chunk.ptsNs, frames: chunk.frameCount)
            return
        }
        window.frames += chunk.frameCount
        rateWindow = window
    }

    // MARK: - Segment lifecycle

    private func framesInCurrent() -> Int {
        current?.writer.framesWritten ?? 0
    }

    private func open(startPtsNs: Int64, startSourceNs: Int64) async throws {
        let sequence = nextSequence
        nextSequence += 1
        let fileName = ProjectLayout.segmentFileName(
            type: trackType, displayID: nil, sequence: sequence)
        let finalURL = directory.appendingPathComponent(fileName)
        let partialURL = directory.appendingPathComponent(fileName + ProjectLayout.partialSuffix)
        let writer = try CAFWriter(url: partialURL, sampleRate: sampleRate, channels: channels)
        try await onOpen(layout.relativePath(of: finalURL), sequence)
        current = OpenSegment(
            writer: writer,
            partialURL: partialURL,
            finalURL: finalURL,
            sequenceInTrack: sequence,
            startPtsNs: startPtsNs,
            startSourceNs: startSourceNs,
            discontinuityBefore: pendingDiscontinuity)
        pendingDiscontinuity = false
    }

    private func closeCurrent(endPtsNs: Int64, endSourceNs: Int64) async throws {
        guard let segment = current else { return }
        current = nil
        let frames = segment.writer.framesWritten
        try segment.writer.close()

        // Basic inspection: the CAF layout is deterministic, so byte size must
        // equal header + frames × channels × 4 exactly.
        let fm = FileManager.default
        let size = ((try? fm.attributesOfItem(atPath: segment.partialURL.path)[.size] as? Int64) ?? nil) ?? -1
        let expectedSize = CAFWriter.pcmDataOffset + Int64(frames * channels * 4)
        guard size == expectedSize, frames > 0 else {
            throw AksError.invariantViolated(
                "CAF segment failed inspection: \(size) bytes, expected \(expectedSize) "
                    + "(\(frames) frames) at \(segment.partialURL.path)")
        }

        let sha = try Hashing.sha256HexOfFile(at: segment.partialURL)
        try AtomicFile.rename(from: segment.partialURL, to: segment.finalURL)
        try AtomicFile.syncDirectory(directory)

        let descriptor = SegmentDescriptor(
            trackID: trackID,
            trackType: trackType,
            path: layout.relativePath(of: segment.finalURL),
            sequenceInTrack: segment.sequenceInTrack,
            container: .caf,
            codec: .pcmFloat32,
            audio: AudioFormatInfo(
                // A confirmed device rate lie stamps the observed standard
                // rate so sampleCount/sampleRate math stays truthful; the
                // CAF file itself keeps its as-written header (raw asset,
                // never mutated).
                sampleRate: observedStandardRate ?? sampleRate,
                channels: channels,
                layout: channels == 1 ? "mono" : (channels == 2 ? "stereo" : "\(channels)ch"),
                bitsPerSample: 32,
                floatingPoint: true,
                sampleCount: frames),
            sourceStartNs: segment.startSourceNs,
            sourceEndNs: endSourceNs,
            normalizedStartNs: segment.startPtsNs,
            normalizedEndNs: endPtsNs,
            byteSize: size,
            sha256: sha,
            discontinuityBefore: segment.discontinuityBefore ? true : nil,
            commitSequence: 0)  // assigned by the session when journaled
        try await onCommit(descriptor)
    }
}
