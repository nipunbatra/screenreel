import Foundation
import ProjectModel
import XCTest

@testable import CaptureCore

/// Clock-mapping contract: normalization is strictly
/// monotonic for monotonic device timestamps at any frame rate with
/// jitter, and replaying the persisted anchor reproduces the exact same
/// mapping — the property that lets presentation times be rebuilt from a
/// crashed session's manifest.
final class ClockMappingFuzzTests: XCTestCase {

    private struct Rng {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
        mutating func jitterNs(_ bound: Int64) -> Int64 {
            Int64(next() % UInt64(2 * bound)) - bound
        }
    }

    func testNormalizationMonotonicAcrossFpsMatrixWithJitter() {
        let clock = SessionClock()
        var rng = Rng(state: 2026_08_25)
        for fps in [24.0, 30, 60, 120] {
            let frameNs = Int64(1_000_000_000 / fps)
            var hostNs: Int64 = 500_000_000_000
            var lastNormalized = Int64.min
            for _ in 0..<2_000 {
                // Jitter bounded to < half a frame keeps input monotonic.
                hostNs += frameNs + rng.jitterNs(frameNs / 2 - 1)
                let normalized = clock.normalizeHostNs(hostNs)
                XCTAssertGreaterThan(normalized, lastNormalized,
                    "fps \(fps): normalization broke monotonicity")
                lastNormalized = normalized
            }
        }
    }

    func testAnchorReplayReproducesIdenticalMapping() throws {
        let original = SessionClock()
        // Round-trip the anchor through JSON exactly as the manifest does.
        let data = try JSONEncoder().encode(original.anchor)
        let anchor = try JSONDecoder().decode(ClockAnchor.self, from: data)
        let replayed = SessionClock(anchor: anchor)
        var rng = Rng(state: 42)
        var hostNs: Int64 = 1_000_000_000
        for _ in 0..<5_000 {
            hostNs += Int64(rng.next() % 50_000_000)
            XCTAssertEqual(
                original.normalizeHostNs(hostNs),
                replayed.normalizeHostNs(hostNs),
                "replayed anchor must reproduce the mapping bit-for-bit")
        }
    }

    func testNormalizationIsAffine() {
        // The mapping must be a pure offset: deltas in == deltas out.
        let clock = SessionClock()
        let a = clock.normalizeHostNs(10_000_000_000)
        let b = clock.normalizeHostNs(10_000_033_333)
        XCTAssertEqual(b - a, 33_333)
    }
}
