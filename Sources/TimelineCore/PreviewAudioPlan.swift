import Foundation

/// One span of raw source audio scheduled during preview playback.
public struct AudioScheduleEntry: Equatable, Sendable {
    /// Where in SOURCE time the audio read begins.
    public let sourceStartNs: Int64
    /// How much source audio to read.
    public let lengthNs: Int64
    /// When the span begins, relative to playback start (OUTPUT domain).
    public let outputOffsetNs: Int64

    public init(sourceStartNs: Int64, lengthNs: Int64, outputOffsetNs: Int64) {
        self.sourceStartNs = sourceStartNs
        self.lengthNs = lengthNs
        self.outputOffsetNs = outputOffsetNs
    }
}

/// Plans clip-aware raw-audio preview: which source spans play, and when,
/// for a playback session starting at `fromOutput`. Cut spans are skipped
/// and sped clips are silent — the same policy the exporter's audio pump
/// applies, so preview and export agree on what you hear.
public enum PreviewAudioPlan {

    public static func entries(
        timeline: ClipTimeline, fromOutput outputStartNs: Int64
    ) -> [AudioScheduleEntry] {
        var result: [AudioScheduleEntry] = []
        var clipOutputStart: Int64 = 0
        for clip in timeline.clips {
            let clipOutputEnd = clipOutputStart + clip.outputLengthNs
            defer { clipOutputStart = clipOutputEnd }
            guard clipOutputEnd > outputStartNs else { continue }
            // Sped clips export silent audio by policy; preview matches.
            guard abs(clip.speed - 1) < 0.001 else { continue }
            let intoClip = max(0, outputStartNs - clipOutputStart)
            // Cap by the clip's OUTPUT span: a hand-edited speed like
            // 1.0005 is played 1:1 (same policy as export) but must never
            // overrun into the next clip's schedule.
            let length = min(
                (clip.sourceEndNs - clip.sourceStartNs) - intoClip,
                clip.outputLengthNs - intoClip)
            guard length > 0 else { continue }
            result.append(AudioScheduleEntry(
                sourceStartNs: clip.sourceStartNs + intoClip,
                lengthNs: length,
                outputOffsetNs: max(0, clipOutputStart - outputStartNs)))
        }
        return result
    }
}
