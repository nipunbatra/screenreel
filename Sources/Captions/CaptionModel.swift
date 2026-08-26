import Foundation
import TimelineCore

/// One caption cue in SOURCE time. Times map through the clip timeline at
/// export, so cuts and speed changes keep captions in sync automatically.
public struct CaptionCue: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var startNs: Int64
    public var endNs: Int64
    public var text: String

    public init(id: UUID = UUID(), startNs: Int64, endNs: Int64, text: String) {
        self.id = id
        self.startNs = startNs
        self.endNs = endNs
        self.text = text
    }
}

public enum CaptionFormat: String, Sendable, CaseIterable {
    case srt, vtt
}

/// Pure caption processing: shaping raw recognition segments into readable
/// cues, remapping through cuts/speeds, and serializing SRT/WebVTT.
public enum CaptionWriter {

    /// Shape raw word/segment timings into display cues: merge fragments
    /// into lines up to `maxCharacters`, split at gaps > `maxGapNs`, clamp
    /// each cue to `minDurationNs…maxDurationNs`.
    public static func shaped(
        _ raw: [CaptionCue],
        maxCharacters: Int = 84,
        maxGapNs: Int64 = 900_000_000,
        minDurationNs: Int64 = 700_000_000,
        maxDurationNs: Int64 = 6_000_000_000
    ) -> [CaptionCue] {
        var cues: [CaptionCue] = []
        var current: CaptionCue?
        for piece in raw.sorted(by: { $0.startNs < $1.startNs }) {
            let text = piece.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            if var open = current {
                let gap = piece.startNs - open.endNs
                let joined = open.text + " " + text
                if gap <= maxGapNs, joined.count <= maxCharacters,
                    piece.endNs - open.startNs <= maxDurationNs
                {
                    open.text = joined
                    open.endNs = piece.endNs
                    current = open
                    continue
                }
                cues.append(open)
            }
            current = CaptionCue(startNs: piece.startNs, endNs: piece.endNs, text: text)
        }
        if let open = current { cues.append(open) }
        // Duration clamps; never overlap the next cue.
        for index in cues.indices {
            if cues[index].endNs - cues[index].startNs < minDurationNs {
                cues[index].endNs = cues[index].startNs + minDurationNs
            }
            if index + 1 < cues.count {
                cues[index].endNs = min(cues[index].endNs, cues[index + 1].startNs)
            }
        }
        return cues.filter { $0.endNs > $0.startNs }
    }

    /// Remap source-time cues onto the OUTPUT timeline: cues entirely in
    /// cut-away spans drop; cues over sped spans compress with them. A cue
    /// survives wherever it overlaps ANY kept content — probing only its
    /// endpoints dropped cues whose middles were kept and collapsed cues
    /// whose heads were cut.
    public static func remapped(
        _ cues: [CaptionCue], through timeline: ClipTimeline
    ) -> [CaptionCue] {
        var result: [CaptionCue] = []
        for cue in cues {
            var outStart: Int64?
            var outEnd: Int64?
            var clipOutputStart: Int64 = 0
            for clip in timeline.clips {
                defer { clipOutputStart += clip.outputLengthNs }
                let overlapStart = max(cue.startNs, clip.sourceStartNs)
                let overlapEnd = min(cue.endNs, clip.sourceEndNs)
                guard overlapEnd > overlapStart else { continue }
                // Same rounding as ClipTimeline.outputTime(forSource:).
                func toOutput(_ sourceNs: Int64) -> Int64 {
                    clipOutputStart + Int64(
                        (Double(sourceNs - clip.sourceStartNs) / clip.speed)
                            .rounded())
                }
                if outStart == nil { outStart = toOutput(overlapStart) }
                outEnd = toOutput(overlapEnd)
            }
            guard let start = outStart, let end = outEnd, end > start
            else { continue }  // no kept overlap at all
            result.append(CaptionCue(
                id: cue.id, startNs: start, endNs: end, text: cue.text))
        }
        return result
    }

    /// Clip output-time cues to the export's trimmed range and rebase them
    /// so the first exported frame is t=0. Cues fully outside drop; cues
    /// straddling an edge are shortened. Without this, any trimmed project
    /// exports captions late by the trim head.
    public static func clipped(
        _ cues: [CaptionCue], toRange range: (startNs: Int64, endNs: Int64)
    ) -> [CaptionCue] {
        cues.compactMap { cue in
            let start = max(cue.startNs, range.startNs)
            let end = min(cue.endNs, range.endNs)
            guard end > start else { return nil }
            return CaptionCue(
                id: cue.id,
                startNs: start - range.startNs,
                endNs: end - range.startNs,
                text: cue.text)
        }
    }

    public static func serialize(
        _ cues: [CaptionCue], format: CaptionFormat
    ) -> String {
        switch format {
        case .srt:
            var out = ""
            for (index, cue) in cues.enumerated() {
                out += "\(index + 1)\n"
                out += "\(timestamp(cue.startNs, format: .srt)) --> \(timestamp(cue.endNs, format: .srt))\n"
                out += cue.text + "\n\n"
            }
            return out
        case .vtt:
            var out = "WEBVTT\n\n"
            for cue in cues {
                out += "\(timestamp(cue.startNs, format: .vtt)) --> \(timestamp(cue.endNs, format: .vtt))\n"
                out += cue.text + "\n\n"
            }
            return out
        }
    }

    /// SRT uses `HH:MM:SS,mmm`; WebVTT uses `HH:MM:SS.mmm`.
    public static func timestamp(_ ns: Int64, format: CaptionFormat) -> String {
        let totalMs = max(0, ns) / 1_000_000
        let ms = totalMs % 1000
        let seconds = (totalMs / 1000) % 60
        let minutes = (totalMs / 60_000) % 60
        let hours = totalMs / 3_600_000
        let separator = format == .srt ? "," : "."
        return String(
            format: "%02d:%02d:%02d%@%03d",
            hours, minutes, seconds, separator, ms)
    }
}
