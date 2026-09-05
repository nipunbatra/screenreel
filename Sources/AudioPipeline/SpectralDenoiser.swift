import Accelerate
import Foundation

/// Streaming spectral noise reduction for mono voice tracks: STFT with
/// per-bin noise-floor tracking and spectral gating (the classic
/// spectral-subtraction family — steady fan/hum/hiss drops away while
/// speech passes). Processes arbitrary-size blocks with internal overlap
/// state, so exporters can feed it their existing pump blocks.
///
/// This never touches raw project audio — it runs on the export path only.
public final class SpectralDenoiser {
    /// Constant streaming delay, independent of caller block size. Offline
    /// consumers compensate with lookahead, not by feeding silent priming.
    public static let latencySamples = 512
    // 512-sample frames at 48 kHz ≈ 10.7 ms, 50% overlap (Hann COLA).
    private let frameSize = 512
    private let hopSize = 256
    private var bins: Int { frameSize / 2 }

    private let fft: FFTSetup
    private let log2n: vDSP_Length
    private let window: [Float]

    // Fixed storage: no frame slices, growing FIFOs, or removeFirst copies
    // on the audio path. Half a frame of leading silence gives the first
    // real samples both Hann overlaps instead of fading the take's onset.
    private var inputFrame = [Float](repeating: 0, count: 512)
    private var inputCount = 256
    private var outputHop = [Float](repeating: 0, count: 256)
    private var hopPosition = 0
    private var windowed = [Float](repeating: 0, count: 512)
    private var real = [Float](repeating: 0, count: 256)
    private var imag = [Float](repeating: 0, count: 256)
    private var output = [Float](repeating: 0, count: 512)
    private var overlapTail: [Float]
    /// Rising-minimum noise floor per bin and smoothed gains. The floor
    /// tracks minima of the TIME-SMOOTHED magnitude — raw white-noise
    /// magnitudes dip near zero every few frames, so raw minima
    /// under-estimate the floor by an order of magnitude and nothing gates.
    private var smoothedMagnitude: [Float]
    /// Two-window rolling minimum (minimum statistics): the floor is the
    /// min of the previous and current ~0.6 s windows, so it can both fall
    /// AND recover, and speech pauses keep re-seeding it while sustained
    /// speech cannot be absorbed for longer than one window.
    private var currentWindowMin: [Float]
    private var previousWindowMin: [Float]
    private var frameInWindow = 0
    private let windowFrames = 112  // ≈0.6 s at 48 kHz / 256-hop
    private var smoothedGain: [Float]
    private var warmupFrames = 0

    /// How aggressively to subtract (1 = exact floor, higher = stronger).
    private let overSubtraction: Float = 3.0
    /// Never attenuate a bin below this (≈ −22 dB) — keeps ambience natural.
    private let gainFloor: Float = 0.08

    public init() {
        log2n = vDSP_Length(log2(Double(frameSize)).rounded())
        fft = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
        var hann = [Float](repeating: 0, count: frameSize)
        // Denormalized Hann (0.5 − 0.5·cos) at 50% overlap sums to exactly
        // 1, so analysis-window-only OLA reconstructs perfectly.
        vDSP_hann_window(&hann, vDSP_Length(frameSize), Int32(vDSP_HANN_DENORM))
        window = hann
        overlapTail = [Float](repeating: 0, count: frameSize - hopSize)
        smoothedMagnitude = [Float](repeating: -1, count: frameSize / 2 + 1)
        currentWindowMin = [Float](
            repeating: .greatestFiniteMagnitude, count: frameSize / 2 + 1)
        previousWindowMin = [Float](
            repeating: .greatestFiniteMagnitude, count: frameSize / 2 + 1)
        smoothedGain = [Float](repeating: 1, count: frameSize / 2 + 1)
    }

    deinit {
        vDSP_destroy_fftsetup(fft)
    }

    /// Process one mono block in place. Output has the same length as the
    /// input, delayed by a constant frameSize samples (zeros at the very
    /// head of the stream); block boundaries are invisible.
    /// When `learning` is false the minimum-statistics clock freezes:
    /// samples are still gated with the CURRENT floor and the latency FIFO
    /// stays aligned, but the tracker ignores them. Exporters pass false for
    /// SYNTHESIZED audio (sped-span silence) — learning a zero floor let
    /// ~1 s of raw noise through after every sped span.
    public func process(_ samples: inout [Float], learning: Bool = true) {
        learningEnabled = learning
        defer { learningEnabled = true }
        processBody(&samples)
    }

    private var learningEnabled = true

    private func processBody(_ samples: inout [Float]) {
        samples.withUnsafeMutableBufferPointer { samples in
            var position = 0
            while position < samples.count {
                let count = min(frameSize - inputCount, samples.count - position)
                inputFrame.withUnsafeMutableBufferPointer { input in
                    input.baseAddress!.advanced(by: inputCount).update(
                        from: samples.baseAddress!.advanced(by: position), count: count)
                }
                outputHop.withUnsafeBufferPointer { hop in
                    samples.baseAddress!.advanced(by: position).update(
                        from: hop.baseAddress!.advanced(by: hopPosition), count: count)
                }
                inputCount += count
                hopPosition += count
                position += count
                if inputCount == frameSize {
                    processFrame()
                    inputFrame.withUnsafeMutableBufferPointer { input in
                        input.baseAddress!.update(
                            from: input.baseAddress!.advanced(by: hopSize), count: hopSize)
                    }
                    inputCount = hopSize
                    hopPosition = 0
                }
            }
        }
    }

    /// One Hann-windowed frame → gated spectrum → overlap-added hop output.
    private func processFrame() {
        let frozen = !learningEnabled
        vDSP_vmul(inputFrame, 1, window, 1, &windowed, 1, vDSP_Length(frameSize))

        windowed.withUnsafeBufferPointer { pointer in
            pointer.baseAddress!.withMemoryRebound(
                to: DSPComplex.self, capacity: bins
            ) { complexPointer in
                real.withUnsafeMutableBufferPointer { realBuffer in
                    imag.withUnsafeMutableBufferPointer { imagBuffer in
                        var split = DSPSplitComplex(
                            realp: realBuffer.baseAddress!,
                            imagp: imagBuffer.baseAddress!)
                        vDSP_ctoz(complexPointer, 2, &split, 1, vDSP_Length(bins))
                        vDSP_fft_zrip(fft, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                    }
                }
            }
        }

        // Packed real FFT: real[0]=DC, imag[0]=Nyquist.
        if !frozen { warmupFrames += 1 }
        if !frozen { frameInWindow += 1 }
        if frameInWindow >= windowFrames {
            frameInWindow = 0
            swap(&previousWindowMin, &currentWindowMin)
            for index in currentWindowMin.indices {
                currentWindowMin[index] = .greatestFiniteMagnitude
            }
        }
        // No gating until a full window has been observed.
        let adapting = warmupFrames < windowFrames
        func gate(magnitude: Float, bin: Int) -> Float {
            // Frozen frames still GATE with the existing floor — only the
            // tracker learns nothing. Returning 1 here would switch the
            // denoiser off for the real audio sharing a block with a sped
            // span.
            if !frozen {
                // Time-smooth the magnitude, seeded from the first frame.
                smoothedMagnitude[bin] = smoothedMagnitude[bin] < 0
                    ? magnitude
                    : 0.85 * smoothedMagnitude[bin] + 0.15 * magnitude
                let tracked = smoothedMagnitude[bin]
                currentWindowMin[bin] = min(currentWindowMin[bin], tracked)
            }
            if adapting { return 1 }
            let floorEstimate = min(previousWindowMin[bin], currentWindowMin[bin])
            let threshold = overSubtraction * floorEstimate
            let cleaned = magnitude - threshold
            let gain = max(gainFloor, min(1, cleaned / max(magnitude, 1e-9)))
            smoothedGain[bin] = 0.55 * smoothedGain[bin] + 0.45 * gain
            return smoothedGain[bin]
        }

        real.withUnsafeMutableBufferPointer { real in
            imag.withUnsafeMutableBufferPointer { imag in
                let dcGain = gate(magnitude: abs(real[0]), bin: 0)
                real[0] *= dcGain
                let nyquistGain = gate(magnitude: abs(imag[0]), bin: bins)
                imag[0] *= nyquistGain
                for bin in 1..<bins {
                    let magnitude = (real[bin] * real[bin] + imag[bin] * imag[bin]).squareRoot()
                    let gain = gate(magnitude: magnitude, bin: bin)
                    real[bin] *= gain
                    imag[bin] *= gain
                }
            }
        }

        real.withUnsafeMutableBufferPointer { realBuffer in
            imag.withUnsafeMutableBufferPointer { imagBuffer in
                var split = DSPSplitComplex(
                    realp: realBuffer.baseAddress!, imagp: imagBuffer.baseAddress!)
                vDSP_fft_zrip(fft, &split, 1, log2n, FFTDirection(FFT_INVERSE))
                output.withUnsafeMutableBufferPointer { outputBuffer in
                    outputBuffer.baseAddress!.withMemoryRebound(
                        to: DSPComplex.self, capacity: bins
                    ) { complexPointer in
                        vDSP_ztoc(&split, 1, complexPointer, 2, vDSP_Length(bins))
                    }
                }
            }
        }
        // zrip forward+inverse scales by 2·n.
        var scale = Float(1.0) / (2 * Float(frameSize))
        vDSP_vsmul(output, 1, &scale, &output, 1, vDSP_Length(frameSize))

        // 50% OLA: emit tail + first half, keep second half as new tail.
        vDSP_vadd(overlapTail, 1, output, 1, &outputHop, 1, vDSP_Length(hopSize))
        output.withUnsafeBufferPointer { output in
            overlapTail.withUnsafeMutableBufferPointer { tail in
                tail.baseAddress!.update(
                    from: output.baseAddress!.advanced(by: hopSize), count: hopSize)
            }
        }
    }
}
