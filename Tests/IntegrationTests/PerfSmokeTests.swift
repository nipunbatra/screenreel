import Foundation
import TimelineCore
import XCTest

@testable import PreviewEngine

/// Coarse performance smoke: prints the numbers that matter for editor
/// feel (open latency, first frame, seek storm) and asserts only generous
/// ceilings so regressions of 10× get caught without flaking under load.
final class PerfSmokeTests: XCTestCase {

    private var directory: URL!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("sr-perf-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    private func ms(_ block: () throws -> Void) rethrows -> Double {
        let start = DispatchTime.now().uptimeNanoseconds
        try block()
        return Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6
    }

    func testEditorOpenAndSeekLatency() async throws {
        let projectURL = try await SyntheticProjectFactory.make(
            in: directory, durationNs: 60_000_000_000)

        // Editor-open cost: the composition constructor (motion timeline,
        // zoom generation, cursor assets, engines).
        var composition: ProjectComposition!
        let openMs = try ms {
            composition = try ProjectComposition(
                projectURL: projectURL, previewDecodeMaxHeight: 1440)
        }

        composition.setOutputSize(SIMD2(1280, 720))
        let firstFrameStart = DispatchTime.now().uptimeNanoseconds
        _ = try await composition.frame(atOutput: 0)
        let firstFrameMs =
            Double(DispatchTime.now().uptimeNanoseconds - firstFrameStart) / 1e6

        // Scrub storm: 40 spread-out seeks (worst-case provider reopens).
        var seed: UInt64 = 0x5DEECE66D
        let scrubStart = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<40 {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1
            let t = Int64(seed % 60_000_000_000)
            _ = try await composition.frame(atOutput: t)
        }
        let perSeekMs =
            Double(DispatchTime.now().uptimeNanoseconds - scrubStart) / 1e6 / 40

        print("PERF editor-open=\(Int(openMs))ms first-frame=\(Int(firstFrameMs))ms seek=\(String(format: "%.1f", perSeekMs))ms/frame")

        XCTAssertLessThan(openMs, 5_000, "editor open regressed an order of magnitude")
        XCTAssertLessThan(firstFrameMs, 3_000)
        XCTAssertLessThan(perSeekMs, 500)
    }
}
