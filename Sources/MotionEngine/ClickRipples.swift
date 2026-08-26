import Foundation

/// Deterministic click-ripple evaluation: every mouse-down spawns a ring
/// that expands and fades over `durationNs`. Pure source-time math shared
/// by preview and export.
public enum ClickRipples {

    public struct Ripple: Equatable, Sendable {
        /// Click position in SOURCE pixels.
        public let position: SIMD2<Double>
        /// 0 at the click instant → 1 when fully faded.
        public let progress: Double

        public init(position: SIMD2<Double>, progress: Double) {
            self.position = position
            self.progress = progress
        }
    }

    public static let defaultDurationNs: Int64 = 450_000_000

    /// Ripples alive at `timeNs`, oldest first. Binary-searches the sorted
    /// click list, so an hour of clicks costs log n per frame.
    public static func active(
        downs: [MotionTimeline.Click],
        atSource timeNs: Int64,
        durationNs: Int64 = defaultDurationNs
    ) -> [Ripple] {
        guard durationNs > 0, !downs.isEmpty else { return [] }
        let windowStart = timeNs - durationNs
        // First index with timeNs > windowStart.
        var low = 0
        var high = downs.count
        while low < high {
            let mid = (low + high) / 2
            if downs[mid].timeNs <= windowStart { low = mid + 1 } else { high = mid }
        }
        var result: [Ripple] = []
        for click in downs[low...] {
            guard click.timeNs <= timeNs else { break }
            let age = timeNs - click.timeNs
            result.append(Ripple(
                position: click.position,
                progress: Double(age) / Double(durationNs)))
        }
        // Autoclicker bursts: keep the NEWEST rings (suffix, like chips).
        return Array(result.suffix(8))
    }
}
