import Foundation

/// One kept span of the source recording, in source time. The edit
/// document's ordered clip list IS the cut: splitting inserts a boundary,
/// ripple-deleting a clip closes the gap in output time. An empty list
/// means "the whole recording, uncut" — every pre-clip project keeps its
/// exact behavior.
public struct Clip: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var sourceStartNs: Int64
    /// Exclusive.
    public var sourceEndNs: Int64
    /// Playback rate: 2 plays the span twice as fast. Clamped 0.25–16.
    /// v1 audio policy: spans with speed ≠ 1 export SILENT audio — the
    /// feature exists to compress dead stretches (typing, waiting), where
    /// the audio is noise; honest silence beats chipmunk resampling.
    public var speed: Double

    public init(
        id: UUID = UUID(), sourceStartNs: Int64, sourceEndNs: Int64,
        speed: Double = 1
    ) {
        self.id = id
        self.sourceStartNs = sourceStartNs
        self.sourceEndNs = sourceEndNs
        self.speed = min(16, max(0.25, speed.isFinite ? speed : 1))
    }

    // Documents written before speed existed decode at 1×.
    private enum CodingKeys: String, CodingKey {
        case id, sourceStartNs, sourceEndNs, speed
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.sourceStartNs = try c.decode(Int64.self, forKey: .sourceStartNs)
        self.sourceEndNs = try c.decode(Int64.self, forKey: .sourceEndNs)
        let raw = try c.decodeIfPresent(Double.self, forKey: .speed) ?? 1
        self.speed = min(16, max(0.25, raw.isFinite ? raw : 1))
    }

    public var lengthNs: Int64 { max(0, sourceEndNs - sourceStartNs) }
    /// Length on the output timeline (source length ÷ speed).
    public var outputLengthNs: Int64 {
        Int64((Double(lengthNs) / speed).rounded())
    }
}

/// Pure output-time ↔ source-time mapping over an ordered clip list.
/// Preview, export, audio, and the timeline UI all evaluate through this
/// one mapping — the preview==export invariant extends to cuts.
public struct ClipTimeline: Sendable, Equatable {
    /// Normalized clips: sorted, clamped to the source, zero-length dropped.
    public let clips: [Clip]
    public let sourceDurationNs: Int64
    /// Cumulative output start of each clip.
    private let outputStarts: [Int64]
    public let outputDurationNs: Int64

    /// `clips` empty ⇒ single implicit clip over the whole source.
    public init(clips: [Clip], sourceDurationNs: Int64) {
        self.sourceDurationNs = max(0, sourceDurationNs)
        let sourceDuration = self.sourceDurationNs
        let effective: [Clip]
        if clips.isEmpty {
            effective = [Clip(sourceStartNs: 0, sourceEndNs: sourceDuration)]
        } else {
            effective = clips
                .map {
                    Clip(
                        id: $0.id,
                        sourceStartNs: max(0, min($0.sourceStartNs, sourceDuration)),
                        sourceEndNs: max(0, min($0.sourceEndNs, sourceDuration)),
                        speed: $0.speed)
                }
                .filter { $0.lengthNs > 0 }
                .sorted { $0.sourceStartNs < $1.sourceStartNs }
        }
        // Guard: never an empty timeline — fall back to the full source.
        self.clips = effective.isEmpty
            ? [Clip(sourceStartNs: 0, sourceEndNs: sourceDuration)]
            : effective
        var starts: [Int64] = []
        var accumulated: Int64 = 0
        for clip in self.clips {
            starts.append(accumulated)
            accumulated += clip.outputLengthNs
        }
        self.outputStarts = starts
        self.outputDurationNs = accumulated
    }

    /// Output → source. Times at or past the end clamp into the last clip.
    public func sourceTime(forOutput outputNs: Int64) -> Int64 {
        let clamped = max(0, min(outputNs, max(0, outputDurationNs - 1)))
        // Binary search: last clip whose output start ≤ clamped.
        var low = 0
        var high = clips.count
        while low < high {
            let mid = (low + high) / 2
            if outputStarts[mid] <= clamped { low = mid + 1 } else { high = mid }
        }
        let index = max(0, low - 1)
        let clip = clips[index]
        let intoOutput = clamped - outputStarts[index]
        let intoSource = Int64((Double(intoOutput) * clip.speed).rounded())
        return min(clip.sourceStartNs + intoSource, max(clip.sourceStartNs, clip.sourceEndNs - 1))
    }

    /// Source → output; nil when the source time was cut away.
    /// NOTE: for a sped clip, the last source sample can round to the NEXT
    /// clip's exact output start (e.g. 4×: source end-1 → +round(249.75) =
    /// the boundary). Callers must not assume the result lies strictly
    /// inside the same clip; use `clipIndex(atOutput:)` when that matters.
    public func outputTime(forSource sourceNs: Int64) -> Int64? {
        for (index, clip) in clips.enumerated() {
            if sourceNs >= clip.sourceStartNs && sourceNs < clip.sourceEndNs {
                let intoSource = sourceNs - clip.sourceStartNs
                return outputStarts[index]
                    + Int64((Double(intoSource) / clip.speed).rounded())
            }
        }
        return nil
    }

    /// Source → output, snapping cut-away times to the nearest kept edge
    /// (for drawing source-anchored overlays like zoom blocks).
    public func outputTimeSnapped(forSource sourceNs: Int64) -> Int64 {
        if let exact = outputTime(forSource: sourceNs) { return exact }
        // Before the first clip / inside a gap / after the last clip.
        for (index, clip) in clips.enumerated() {
            if sourceNs < clip.sourceStartNs {
                return outputStarts[index]
            }
        }
        return outputDurationNs
    }

    /// The clip containing an output time.
    public func clipIndex(atOutput outputNs: Int64) -> Int {
        let clamped = max(0, min(outputNs, max(0, outputDurationNs - 1)))
        var low = 0
        var high = clips.count
        while low < high {
            let mid = (low + high) / 2
            if outputStarts[mid] <= clamped { low = mid + 1 } else { high = mid }
        }
        return max(0, low - 1)
    }

    public func outputStart(ofClipAt index: Int) -> Int64 {
        outputStarts[index]
    }

    // MARK: - Edit operations (pure: return the new clip list)

    /// Minimum clip length a split may produce.
    public static let minClipLengthNs: Int64 = 100_000_000

    /// Split at an output-time playhead. No-op when either side would be
    /// shorter than the minimum.
    public func splitting(atOutput outputNs: Int64) -> [Clip] {
        let index = clipIndex(atOutput: outputNs)
        let clip = clips[index]
        let sourceCut = sourceTime(forOutput: outputNs)
        guard sourceCut - clip.sourceStartNs >= Self.minClipLengthNs,
            clip.sourceEndNs - sourceCut >= Self.minClipLengthNs
        else { return clips }
        var result = clips
        result[index] = Clip(
            id: clip.id, sourceStartNs: clip.sourceStartNs,
            sourceEndNs: sourceCut, speed: clip.speed)
        result.insert(
            Clip(
                sourceStartNs: sourceCut, sourceEndNs: clip.sourceEndNs,
                speed: clip.speed),
            at: index + 1)
        return result
    }

    /// Change one clip's playback rate.
    public func settingSpeed(_ speed: Double, clipID: UUID) -> [Clip] {
        clips.map { clip in
            guard clip.id == clipID else { return clip }
            var changed = clip
            changed.speed = min(16, max(0.25, speed.isFinite ? speed : 1))
            return changed
        }
    }

    /// Ripple delete: remove the clip, later output times close the gap.
    /// Deleting the only clip is a no-op (a timeline must keep content).
    public func deleting(clipID: UUID) -> [Clip] {
        guard clips.count > 1 else { return clips }
        return clips.filter { $0.id != clipID }
    }
}
