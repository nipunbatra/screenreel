import Foundation

/// Pure level-meter math, shared by the pre-record mic meter and tests.
public enum AudioLevel {

    /// RMS of one channel of float samples.
    public static func rms(_ samples: UnsafePointer<Float>, count: Int) -> Double {
        guard count > 0 else { return 0 }
        var sum: Float = 0
        for index in 0..<count {
            sum += samples[index] * samples[index]
        }
        return Double(sum / Float(count)).squareRoot()
    }

    /// Map an RMS amplitude onto a 0…1 meter: roughly −50 dBFS…0 dBFS,
    /// clamped, with silence pinned to 0.
    public static func meterValue(rms: Double) -> Double {
        let db = 20 * log10(max(rms, 1e-6))
        return min(1, max(0, (db + 50) / 50))
    }

    /// One smoothing step (fast attack, slower decay feel at ~20 Hz update).
    public static func smoothed(previous: Double, next: Double) -> Double {
        previous * 0.6 + next * 0.4
    }
}
