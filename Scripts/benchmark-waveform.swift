// Compile with AudioWaveform.swift and the ProjectModel objects. Compare
// identical release-optimized builds; source file may come from an older ref.
import AVFoundation
import Foundation
import ProjectModel

@main struct WaveformBenchmark {
    static func main() throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let layout = ProjectLayout(root: root)
        try FileManager.default.createDirectory(at: layout.microphoneDirectory, withIntermediateDirectories: true)
        let url = layout.microphoneDirectory.appendingPathComponent("benchmark.caf")
        let seconds = 120
        if !FileManager.default.fileExists(atPath: url.path) {
            let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48_000)!
            buffer.frameLength = 48_000
            for c in 0..<2 { for i in 0..<48_000 {
                buffer.floatChannelData![c][i] = Float(sin(Double(i) * 0.031 + Double(c))) * 0.8
            }}
            for _ in 0..<seconds { try file.write(from: buffer) }
        }
        let segment = SegmentDescriptor(trackID: UUID(), trackType: .microphone,
            path: "raw/microphone/benchmark.caf", sequenceInTrack: 1,
            container: .caf, codec: .pcmFloat32, sourceStartNs: 0,
            sourceEndNs: Int64(seconds) * 1_000_000_000,
            normalizedStartNs: 0, normalizedEndNs: Int64(seconds) * 1_000_000_000,
            byteSize: 0, sha256: "", commitSequence: 1)
        var times: [Double] = []
        for run in 0..<6 {
            let start = DispatchTime.now().uptimeNanoseconds
            let peaks = AudioWaveform.peaks(segments: [segment], layout: layout,
                durationNs: Int64(seconds) * 1_000_000_000)
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9
            guard peaks.count == 400, peaks.allSatisfy({ $0 > 0.79 && $0 <= 0.8 }) else {
                fatalError("Benchmark waveform is incorrect")
            }
            if run > 0 { times.append(elapsed) }
        }
        print("120 s stereo 48 kHz, 400 buckets, cached file, one warmup")
        print("runs_seconds=\(times)")
        print("median_seconds=\(times.sorted()[2])")
    }
}
