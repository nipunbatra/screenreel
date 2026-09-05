import Foundation

/// Headless, deterministic benchmark. Compile alongside SpectralDenoiser.swift:
/// swiftc -O Sources/AudioPipeline/SpectralDenoiser.swift Scripts/benchmark-denoiser.swift -o /tmp/screenreel-denoise-bench
@main
enum DenoiserBenchmark {
    static func main() {
        let seconds = 60
        let blockSize = 24_000
        var seed: UInt64 = 42
        let input: [Float] = (0..<blockSize).map { index in
            seed = seed &* 6364136223846793005 &+ 1
            let noise = Float(Int32(truncatingIfNeeded: seed >> 32)) / Float(Int32.max) * 0.04
            return noise + (index < 14_400 ? Float(sin(Double(index) * 2 * .pi * 440 / 48_000)) * 0.3 : 0)
        }
        for run in 1...3 {
            let denoiser = SpectralDenoiser()
            let start = ContinuousClock.now
            var checksum: Float = 0
            for _ in 0..<(seconds * 48_000 / blockSize) {
                var block = input
                denoiser.process(&block)
                checksum += block[blockSize / 2]
            }
            let elapsed = start.duration(to: .now)
            let wall = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
            print(String(format: "run=%d audio=%ds wall=%.4fs speed=%.1fx checksum=%.6f", run, seconds, wall, Double(seconds) / wall, checksum))
        }
    }
}
