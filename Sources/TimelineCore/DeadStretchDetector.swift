import Foundation

/// Finds "dead stretches" of a lecture recording — spans with no clicks,
/// almost no cursor travel, and quiet audio — the parts worth playing at
/// 4×. Pure function over pre-digested activity data so it is fully
/// unit-testable; the editor turns the result into sped clips (undoable).
public enum DeadStretchDetector {

    public struct Inputs: Sendable {
        /// Click timestamps (source ns).
        public var clickTimesNs: [Int64]
        /// Cursor samples (source ns, position px), time-ordered.
        public var cursorSamples: [(timeNs: Int64, x: Double, y: Double)]
        /// Uniform audio-level buckets (0…1) spanning the source duration.
        public var audioLevels: [Float]
        public var sourceDurationNs: Int64

        public init(
            clickTimesNs: [Int64],
            cursorSamples: [(timeNs: Int64, x: Double, y: Double)],
            audioLevels: [Float],
            sourceDurationNs: Int64
        ) {
            self.clickTimesNs = clickTimesNs
            self.cursorSamples = cursorSamples
            self.audioLevels = audioLevels
            self.sourceDurationNs = sourceDurationNs
        }
    }

    public struct Thresholds: Sendable {
        /// A span must be at least this long to be worth compressing.
        public var minimumSpanNs: Int64 = 8_000_000_000
        /// Analysis granularity.
        public var windowNs: Int64 = 1_000_000_000
        /// Cursor travel below this (px/window) counts as idle.
        public var maxCursorTravelPx: Double = 40
        /// Audio level below this (0…1) counts as quiet.
        public var maxAudioLevel: Float = 0.12
        /// Keep this margin of real-time playback at each edge, so the
        /// speed-up never clips the surrounding action.
        public var edgeMarginNs: Int64 = 1_000_000_000

        public init() {}
    }

    /// Dead spans, in source time, non-overlapping and ordered.
    public static func detect(
        _ inputs: Inputs, thresholds: Thresholds = Thresholds()
    ) -> [(startNs: Int64, endNs: Int64)] {
        guard inputs.sourceDurationNs > thresholds.minimumSpanNs else { return [] }
        let windowNs = max(200_000_000, thresholds.windowNs)
        let windowCount = Int(inputs.sourceDurationNs / windowNs)
        guard windowCount > 2 else { return [] }

        // Per-window activity flags.
        var active = [Bool](repeating: false, count: windowCount)

        for click in inputs.clickTimesNs {
            let index = Int(click / windowNs)
            if index >= 0 && index < windowCount { active[index] = true }
        }

        // Cursor travel per window.
        var travel = [Double](repeating: 0, count: windowCount)
        var previous: (timeNs: Int64, x: Double, y: Double)?
        for sample in inputs.cursorSamples {
            if let last = previous {
                let index = Int(sample.timeNs / windowNs)
                if index >= 0 && index < windowCount {
                    let dx = sample.x - last.x
                    let dy = sample.y - last.y
                    travel[index] += (dx * dx + dy * dy).squareRoot()
                }
            }
            previous = sample
        }
        for index in 0..<windowCount where travel[index] > thresholds.maxCursorTravelPx {
            active[index] = true
        }

        // Audio energy per window (levels array may have any granularity).
        if !inputs.audioLevels.isEmpty {
            for index in 0..<windowCount {
                let fraction = Double(index) / Double(windowCount)
                let bucket = min(
                    inputs.audioLevels.count - 1,
                    Int(fraction * Double(inputs.audioLevels.count)))
                if inputs.audioLevels[bucket] > thresholds.maxAudioLevel {
                    active[index] = true
                }
            }
        }

        // Coalesce runs of idle windows into spans, trim edge margins,
        // keep only spans meeting the minimum.
        var spans: [(startNs: Int64, endNs: Int64)] = []
        var runStart: Int?
        for index in 0...windowCount {
            let idle = index < windowCount && !active[index]
            if idle, runStart == nil {
                runStart = index
            } else if !idle, let start = runStart {
                runStart = nil
                let rawStart = Int64(start) * windowNs
                let rawEnd = Int64(index) * windowNs
                let trimmedStart = rawStart + thresholds.edgeMarginNs
                let trimmedEnd = rawEnd - thresholds.edgeMarginNs
                if trimmedEnd - trimmedStart >= thresholds.minimumSpanNs {
                    spans.append((trimmedStart, trimmedEnd))
                }
            }
        }
        return spans
    }

    /// Apply detected spans to a clip list: split around each span and set
    /// the inner clip to `speed`. Returns the new clip list.
    public static func applying(
        spans: [(startNs: Int64, endNs: Int64)],
        to timeline: ClipTimeline,
        speed: Double = 4
    ) -> [Clip] {
        var clips = timeline.clips
        for span in spans {
            var working = ClipTimeline(
                clips: clips, sourceDurationNs: timeline.sourceDurationNs)
            if let outStart = working.outputTime(forSource: span.startNs) {
                clips = working.splitting(atOutput: outStart)
            }
            working = ClipTimeline(
                clips: clips, sourceDurationNs: timeline.sourceDurationNs)
            if let outEnd = working.outputTime(forSource: span.endNs) {
                clips = working.splitting(atOutput: outEnd)
            }
            working = ClipTimeline(
                clips: clips, sourceDurationNs: timeline.sourceDurationNs)
            // Every clip fully inside the span gets the speed. Rebuild the
            // timeline per assignment: applying each speed to the ORIGINAL
            // `working` would discard all but the last one when the span
            // holds several clips (e.g. the user split inside it earlier).
            for clip in working.clips
            where clip.sourceStartNs >= span.startNs - 1_000_000
                && clip.sourceEndNs <= span.endNs + 1_000_000
            {
                clips = ClipTimeline(
                    clips: clips, sourceDurationNs: timeline.sourceDurationNs
                ).settingSpeed(speed, clipID: clip.id)
            }
        }
        return clips
    }
}
