import Foundation
import XCTest

@testable import AudioPipeline

/// The export-time noise reducer: steady noise drops, the voice-band tone
/// survives, silence stays silent, and block sizes never change lengths.
final class SpectralDenoiserTests: XCTestCase {

    /// Speech-like signal: tone bursts (0.3 s on / 0.2 s off — syllable
    /// cadence) over optional steady noise. Minimum-statistics denoisers
    /// are designed for modulated speech; a constant infinite tone is
    /// indistinguishable from background by construction.
    private func makeSignal(
        seconds: Double, sampleRate: Double = 48_000,
        toneHz: Double, toneAmp: Float, noiseAmp: Float,
        toneOnAfter: Double = 0
    ) -> [Float] {
        let count = Int(seconds * sampleRate)
        var generator = SystemRandomNumberGenerator()
        return (0..<count).map { index in
            let t = Double(index) / sampleRate
            let cyclePosition = (t - toneOnAfter).truncatingRemainder(dividingBy: 0.5)
            let burstOn = t >= toneOnAfter && cyclePosition < 0.3
            let tone = burstOn ? toneAmp * Float(sin(2 * .pi * toneHz * t)) : 0
            let noise = noiseAmp * Float.random(in: -1...1, using: &generator)
            return tone + noise
        }
    }

    private func rms(_ samples: ArraySlice<Float>) -> Double {
        guard !samples.isEmpty else { return 0 }
        let sum = samples.reduce(Double(0)) { $0 + Double($1) * Double($1) }
        return (sum / Double(samples.count)).squareRoot()
    }

    func testSteadyNoiseDropsSubstantially() {
        // 2 s noise-only lead-in (the two-window floor needs ~0.6 s to
        // engage), then speech-like tone bursts over the same noise.
        let signal = makeSignal(
            seconds: 5, toneHz: 440, toneAmp: 0.4, noiseAmp: 0.05,
            toneOnAfter: 2.0)
        let denoiser = SpectralDenoiser()
        var processed = signal
        // Feed in exporter-sized blocks.
        var output = [Float]()
        var cursor = 0
        while cursor < processed.count {
            let end = min(cursor + 24_000, processed.count)
            var block = Array(processed[cursor..<end])
            denoiser.process(&block)
            output.append(contentsOf: block)
            cursor = end
        }
        processed = output

        // Noise-only region with the floor fully adapted (1–2 s):
        let sampleRate = 48_000
        let noisyIn = rms(signal[sampleRate..<(2 * sampleRate)])
        let noisyOut = rms(processed[sampleRate..<(2 * sampleRate)])
        let reductionDb = 20 * log10(max(noisyOut, 1e-9) / max(noisyIn, 1e-9))
        XCTAssertLessThan(reductionDb, -8, "noise only dropped \(reductionDb) dB")

        // Speech-band bursts keep most of their energy.
        let toneIn = rms(signal[(3 * sampleRate)..<(4 * sampleRate)])
        let toneOut = rms(processed[(3 * sampleRate)..<(4 * sampleRate)])
        XCTAssertGreaterThan(toneOut / toneIn, 0.6, "tone lost too much energy")
    }

    func testSilenceStaysSilent() {
        var block = [Float](repeating: 0, count: 48_000)
        let denoiser = SpectralDenoiser()
        denoiser.process(&block)
        XCTAssertLessThan(rms(block[0...]), 1e-6)
    }

    func testOutputIsIdenticalForAnyBlockPartitioning() {
        // Streaming state must make block boundaries invisible: chopping
        // the same signal differently may not change a single sample.
        let signal = makeSignal(seconds: 2, toneHz: 500, toneAmp: 0.3, noiseAmp: 0.02)

        func run(blockSizes: [Int]) -> [Float] {
            let denoiser = SpectralDenoiser()
            var output = [Float]()
            var cursor = 0
            var sizes = blockSizes
            while cursor < signal.count {
                let size = min(sizes.isEmpty ? 24_000 : sizes.removeFirst(),
                               signal.count - cursor)
                var block = Array(signal[cursor..<cursor + size])
                denoiser.process(&block)
                output.append(contentsOf: block)
                cursor += size
            }
            return output
        }

        let uniform = run(blockSizes: [])
        let ragged = run(blockSizes: [100, 7000, 256, 513, 24_000, 1, 999])
        XCTAssertEqual(uniform.count, ragged.count)
        var maxDelta: Float = 0
        for index in 0..<uniform.count {
            maxDelta = max(maxDelta, abs(uniform[index] - ragged[index]))
        }
        XCTAssertLessThan(maxDelta, 1e-4, "block partitioning changed the output")
    }

    func testBlockLengthsArePreserved() {
        let denoiser = SpectralDenoiser()
        for size in [100, 24_000, 5_000, 256, 24_000] {
            var block = [Float](repeating: 0.1, count: size)
            denoiser.process(&block)
            XCTAssertEqual(block.count, size)
        }
    }

    func testCleanModulatedToneSurvivesNearlyIntact() {
        // No noise at all: the gate must not chew up clean audio badly.
        let signal = makeSignal(seconds: 3, toneHz: 300, toneAmp: 0.5, noiseAmp: 0)
        let denoiser = SpectralDenoiser()
        var processed = signal
        denoiser.process(&processed)
        let sampleRate = 48_000
        let inRMS = rms(signal[sampleRate..<(2 * sampleRate)])
        let outRMS = rms(processed[sampleRate..<(2 * sampleRate)])
        XCTAssertGreaterThan(outRMS / inRMS, 0.6)
    }
}

extension SpectralDenoiserTests {
    /// Digital silence (synthesized sped-span audio) must not teach the
    /// noise-floor tracker: after a long all-zero span, steady noise is
    /// still attenuated as before the span — no ~1 s of raw hum while a
    /// zero floor re-learns.
    func testAllZeroSpanDoesNotPoisonNoiseFloor() {
        let sampleRate = 48_000
        let denoiser = SpectralDenoiser()
        var generator = SystemRandomNumberGenerator()
        func noiseBlock(_ seconds: Double) -> [Float] {
            (0..<Int(Double(sampleRate) * seconds)).map { _ in
                Float.random(in: -0.05...0.05, using: &generator)
            }
        }
        func rms(_ samples: [Float]) -> Float {
            guard !samples.isEmpty else { return 0 }
            return (samples.reduce(0) { $0 + $1 * $1 } / Float(samples.count))
                .squareRoot()
        }

        // Adapt on 4 s of steady noise, then measure attenuation.
        var warmup = noiseBlock(4)
        denoiser.process(&warmup)
        var before = noiseBlock(1)
        let beforeInputRMS = rms(before)
        denoiser.process(&before)
        let attenuatedBefore = rms(before) / max(beforeInputRMS, 1e-9)

        // 3 s of synthesized silence, fed the way the exporter feeds
        // sped spans (learning off) — enough to rotate both
        // minimum-statistics windows if the clock were still running.
        var silence = [Float](repeating: 0, count: sampleRate * 3)
        denoiser.process(&silence, learning: false)

        // Skip one latency-sized block, then measure again.
        var flush = noiseBlock(0.25)
        denoiser.process(&flush)
        var after = noiseBlock(1)
        let afterInputRMS = rms(after)
        denoiser.process(&after)
        let attenuatedAfter = rms(after) / max(afterInputRMS, 1e-9)

        XCTAssertLessThan(
            attenuatedBefore, 0.6, "denoiser must attenuate steady noise")
        XCTAssertLessThan(
            attenuatedAfter, attenuatedBefore * 1.8 + 0.05,
            "noise floor was poisoned by digital silence")
    }
}

extension SpectralDenoiserTests {
    /// Codex regression: a learning-off block containing REAL noise (the
    /// mixed block at a sped-span boundary) must still be gated with the
    /// existing floor — learning-off must not mean denoising-off.
    func testLearningOffStillGatesRealAudio() {
        let sampleRate = 48_000
        let denoiser = SpectralDenoiser()
        var generator = SystemRandomNumberGenerator()
        func noiseBlock(_ seconds: Double) -> [Float] {
            (0..<Int(Double(sampleRate) * seconds)).map { _ in
                Float.random(in: -0.05...0.05, using: &generator)
            }
        }
        func rms(_ samples: [Float]) -> Float {
            (samples.reduce(0) { $0 + $1 * $1 } / Float(max(samples.count, 1)))
                .squareRoot()
        }

        var warmup = noiseBlock(4)
        denoiser.process(&warmup)

        // The boundary block: real noise, learning disabled.
        var boundary = noiseBlock(0.5)
        let inputRMS = rms(boundary)
        denoiser.process(&boundary, learning: false)
        // Drop the first latency-sized chunk (it carries prior audio).
        let settled = Array(boundary.dropFirst(1024))
        XCTAssertLessThan(
            rms(settled) / max(inputRMS, 1e-9), 0.6,
            "learning-off block bypassed the gate entirely")
    }
}
