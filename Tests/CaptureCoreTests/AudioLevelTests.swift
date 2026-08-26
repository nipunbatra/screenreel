import XCTest

@testable import CaptureCore

/// The mic-meter math (kept pure after the tap-closure crash: the level
/// pipeline is now data in, data out, with no actor state anywhere near
/// the audio queue).
final class AudioLevelTests: XCTestCase {

    func testRMSOfKnownSignals() {
        let silence = [Float](repeating: 0, count: 512)
        silence.withUnsafeBufferPointer {
            XCTAssertEqual(AudioLevel.rms($0.baseAddress!, count: 512), 0)
        }
        let fullScale = [Float](repeating: 1, count: 512)
        fullScale.withUnsafeBufferPointer {
            XCTAssertEqual(AudioLevel.rms($0.baseAddress!, count: 512), 1, accuracy: 1e-6)
        }
        // ±0.5 square wave has RMS 0.5.
        let square = (0..<512).map { Float($0 % 2 == 0 ? 0.5 : -0.5) }
        square.withUnsafeBufferPointer {
            XCTAssertEqual(AudioLevel.rms($0.baseAddress!, count: 512), 0.5, accuracy: 1e-6)
        }
    }

    func testRMSEmptyBufferIsZero() {
        let empty = [Float](repeating: 0, count: 1)
        empty.withUnsafeBufferPointer {
            XCTAssertEqual(AudioLevel.rms($0.baseAddress!, count: 0), 0)
        }
    }

    func testMeterValueMapsDecibelRange() {
        // Silence pins to 0, full scale to 1, −25 dB lands mid-meter.
        XCTAssertEqual(AudioLevel.meterValue(rms: 0), 0)
        XCTAssertEqual(AudioLevel.meterValue(rms: 1), 1, accuracy: 1e-9)
        let quarter = AudioLevel.meterValue(rms: pow(10, -25.0 / 20))
        XCTAssertEqual(quarter, 0.5, accuracy: 0.01)
        // Over-unity input clamps rather than overflowing the bar.
        XCTAssertEqual(AudioLevel.meterValue(rms: 4), 1)
    }

    func testMeterValueIsMonotonic() {
        var previous = -1.0
        for rms in stride(from: 0.0, through: 1.0, by: 0.05) {
            let value = AudioLevel.meterValue(rms: rms)
            XCTAssertGreaterThanOrEqual(value, previous)
            previous = value
        }
    }

    func testSmoothingConvergesWithoutOvershoot() {
        var level = 0.0
        for _ in 0..<40 {
            level = AudioLevel.smoothed(previous: level, next: 0.8)
        }
        XCTAssertEqual(level, 0.8, accuracy: 0.001)
        // One step never jumps past the target.
        let step = AudioLevel.smoothed(previous: 0, next: 1)
        XCTAssertLessThan(step, 1)
        XCTAssertGreaterThan(step, 0)
    }
}
