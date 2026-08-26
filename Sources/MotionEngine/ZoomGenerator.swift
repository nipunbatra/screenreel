import Foundation
import ProjectModel
import TimelineCore

/// Click-driven automatic zoom generation (`docs/MOTION_ENGINE.md` §6-7).
/// Generated segments are ordinary editable data tagged `origin=generated`
/// with a generator version, so regeneration can diff instead of clobber.
public enum ZoomGenerator {
    public static let version = 1

    public struct Policy: Codable, Sendable, Equatable {
        public var preClickNs: Int64
        public var postClickNs: Int64
        public var mergeGapNs: Int64
        public var clipTailIgnoreNs: Int64
        public var endMarginNs: Int64
        public var minStartNs: Int64
        public var defaultScale: Double
        public var snapRatio: Double

        public init(
            preClickNs: Int64 = 300_000_000,
            postClickNs: Int64 = 2_500_000_000,
            mergeGapNs: Int64 = 2_500_000_000,
            clipTailIgnoreNs: Int64 = 1_000_000_000,
            endMarginNs: Int64 = 800_000_000,
            minStartNs: Int64 = 1_000_000,
            defaultScale: Double = 2.0,
            snapRatio: Double = 0.25
        ) {
            self.preClickNs = preClickNs
            self.postClickNs = postClickNs
            self.mergeGapNs = mergeGapNs
            self.clipTailIgnoreNs = clipTailIgnoreNs
            self.endMarginNs = endMarginNs
            self.minStartNs = minStartNs
            self.defaultScale = defaultScale
            self.snapRatio = snapRatio
        }
    }

    /// - Parameters:
    ///   - discontinuities: times a zoom must never span (cuts, pauses,
    ///     display changes).
    ///   - sourceSize: captured source dimensions in pixels, for focal
    ///     normalization.
    public static func generate(
        timeline: MotionTimeline,
        durationNs: Int64,
        discontinuities: [Int64] = [],
        sourceSize: SIMD2<Double>,
        policy: Policy = Policy()
    ) -> [ZoomSegment] {
        // Physical clicks: mouseDown events (mouseUp de-duplicated, spec §6),
        // ignoring clicks in the final stretch of the clip.
        let clicks = timeline.downs.filter {
            $0.timeNs <= durationNs - policy.clipTailIgnoreNs
        }
        guard !clicks.isEmpty else { return [] }

        // A zoom must never span a discontinuity, so each candidate is
        // confined to its click's inter-barrier interval up front, and only
        // candidates in the same interval may merge.
        let barriers = discontinuities.sorted()
        func interval(of timeNs: Int64) -> Int {
            var index = 0
            for barrier in barriers where barrier <= timeNs { index += 1 }
            return index
        }

        struct Candidate {
            var startNs: Int64
            var endNs: Int64
            var interval: Int
            var clicks: [MotionTimeline.Click]
        }
        let candidates: [Candidate] = clicks.compactMap { click in
            var start = max(policy.minStartNs, click.timeNs - policy.preClickNs)
            var end = min(durationNs - policy.endMarginNs, click.timeNs + policy.postClickNs)
            for barrier in barriers {
                if barrier <= click.timeNs {
                    start = max(start, barrier)
                } else {
                    end = min(end, barrier)
                    break
                }
            }
            guard end > start else { return nil }
            return Candidate(
                startNs: start, endNs: end,
                interval: interval(of: click.timeNs), clicks: [click])
        }

        // Merge candidates whose gaps are within the merge window (only
        // within one inter-barrier interval by construction).
        var merged: [Candidate] = []
        for candidate in candidates {
            if var last = merged.last,
                candidate.interval == last.interval,
                candidate.startNs - last.endNs <= policy.mergeGapNs
            {
                last.startNs = min(last.startNs, candidate.startNs)
                last.endNs = max(last.endNs, candidate.endNs)
                last.clicks.append(contentsOf: candidate.clicks)
                merged[merged.count - 1] = last
            } else {
                merged.append(candidate)
            }
        }

        return merged.map { candidate in
            let focal = focalPoint(
                clicks: candidate.clicks, sourceSize: sourceSize,
                scale: policy.defaultScale, snapRatio: policy.snapRatio)
            return ZoomSegment(
                startNs: candidate.startNs,
                endNs: candidate.endNs,
                scale: policy.defaultScale,
                focalX: focal.x,
                focalY: focal.y,
                origin: "generated",
                generatorVersion: version)
        }
    }

    /// Auto focal point (spec §7): click bounding-box center, normalized to
    /// screen-local coordinates, clamped so the zoomed viewport never shows
    /// past the source edges, with edge snapping.
    public static func focalPoint(
        clicks: [MotionTimeline.Click],
        sourceSize: SIMD2<Double>,
        scale: Double,
        snapRatio: Double
    ) -> SIMD2<Double> {
        guard !clicks.isEmpty, sourceSize.x > 0, sourceSize.y > 0 else {
            return SIMD2(0.5, 0.5)
        }
        let xs = clicks.map(\.position.x)
        let ys = clicks.map(\.position.y)
        let center = SIMD2(
            (xs.min()! + xs.max()!) / 2 / sourceSize.x,
            (ys.min()! + ys.max()!) / 2 / sourceSize.y)
        return clampFocal(center, scale: scale, snapRatio: snapRatio)
    }

    /// Clamp so a viewport of size 1/scale centered on the focal stays inside
    /// [0,1]; snap fully to the edge when the focal is within `snapRatio` of it.
    public static func clampFocal(
        _ focal: SIMD2<Double>, scale: Double, snapRatio: Double
    ) -> SIMD2<Double> {
        let halfViewport = 0.5 / max(scale, 1)
        func axis(_ value: Double) -> Double {
            if value < snapRatio { return halfViewport }
            if value > 1 - snapRatio { return 1 - halfViewport }
            return min(1 - halfViewport, max(halfViewport, value))
        }
        return SIMD2(axis(focal.x), axis(focal.y))
    }
}
