import XCTest

@testable import Diagnostics
@testable import ProjectModel

final class PerfSamplerTests: XCTestCase {

    func testSamplerReportsRatesOverTheInterval() throws {
        let sampler = PerfSampler()
        let baseline = sampler.sample()
        XCTAssertEqual(baseline.intervalNs, 0)
        XCTAssertEqual(baseline.processCPUPercent, 0)
        XCTAssertGreaterThan(baseline.residentBytes, 0)
        XCTAssertFalse(baseline.thermalState.isEmpty)

        // Burn a little CPU so the process rate is measurably non-zero.
        var sink = 0.0
        let until = Date().addingTimeInterval(0.15)
        while Date() < until { sink += sin(sink + 1) }
        XCTAssertNotEqual(sink, 12345)

        let second = sampler.sample()
        XCTAssertGreaterThan(second.intervalNs, 100_000_000)
        XCTAssertGreaterThan(second.processCPUPercent, 5)
        XCTAssertLessThan(second.processCPUPercent, 1600)  // ≤ core count × 100
        if let system = second.systemCPUPercent {
            XCTAssertGreaterThanOrEqual(system, 0)
            XCTAssertLessThanOrEqual(system, 100)
        }
        let fields = second.fields
        XCTAssertNotNil(fields["processCPUPercent"]?.doubleValue)
        XCTAssertNotNil(fields["residentBytes"]?.integerValue)
    }

    func testSummaryIsIntervalWeightedAndIgnoresBaselineForRates() {
        func sample(_ interval: Int64, cpu: Double, sys: Double?, rss: Int64, thermal: String)
            -> PerfSample
        {
            PerfSample(
                wallNs: 0, intervalNs: interval, processCPUPercent: cpu,
                systemCPUPercent: sys, residentBytes: rss,
                thermalState: thermal, loadAverage1: 1)
        }
        let samples = [
            sample(0, cpu: 0, sys: nil, rss: 100, thermal: "nominal"),  // baseline
            sample(1_000_000_000, cpu: 20, sys: 40, rss: 300, thermal: "fair"),
            sample(3_000_000_000, cpu: 60, sys: 80, rss: 200, thermal: "nominal"),
        ]
        let summary = PerfSummary.summarize(
            samples,
            counters: [
                "videoFrames": .integer(120), "droppedVideoFrames": .integer(0),
                "tapMaxCallbackUs": .integer(400), "tapReenables": .integer(0),
            ])
        XCTAssertEqual(summary.samples, 3)
        XCTAssertEqual(summary.durationNs, 4_000_000_000)
        XCTAssertEqual(summary.averageProcessCPUPercent, 50, accuracy: 0.001)  // (20·1 + 60·3)/4
        XCTAssertEqual(summary.peakProcessCPUPercent, 60)
        XCTAssertEqual(summary.averageSystemCPUPercent ?? 0, 70, accuracy: 0.001)
        XCTAssertEqual(summary.peakSystemCPUPercent, 80)
        XCTAssertEqual(summary.peakResidentBytes, 300)
        XCTAssertEqual(summary.worstThermalState, "fair")
        XCTAssertTrue(summary.headline.contains("avg CPU 50% (peak 60%)"), summary.headline)
        XCTAssertTrue(summary.headline.contains("120 frames, 0 dropped"), summary.headline)
        XCTAssertTrue(summary.headline.contains("tap max 0.4 ms"), summary.headline)
        XCTAssertTrue(summary.concerns.isEmpty, "\(summary.concerns)")
    }

    func testConcernsFlagDropsTapStallsAndSaturation() {
        let hot = PerfSample(
            wallNs: 0, intervalNs: 1_000_000_000, processCPUPercent: 300,
            systemCPUPercent: 99, residentBytes: 1, thermalState: "serious",
            loadAverage1: 20)
        let summary = PerfSummary.summarize(
            [hot],
            counters: [
                "droppedVideoFrames": .integer(7), "droppedBuffers": .integer(2),
                "tapReenables": .integer(1), "tapMaxCallbackUs": .integer(45_000),
            ])
        let concerns = summary.concerns
        XCTAssertEqual(concerns.count, 6, "\(concerns)")
        XCTAssertTrue(concerns.contains { $0.contains("7 video frame") })
        XCTAssertTrue(concerns.contains { $0.contains("re-enabled") })
        XCTAssertTrue(concerns.contains { $0.contains("45 ms") })
        XCTAssertTrue(concerns.contains { $0.contains("99% CPU") })
        XCTAssertTrue(concerns.contains { $0.contains("serious") })
        XCTAssertTrue(summary.headline.contains("thermal serious"))
        XCTAssertTrue(summary.headline.contains("tap re-enabled 1×"))
    }

    func testSummaryRoundTripsThroughJSON() throws {
        let summary = PerfSummary.summarize(
            [PerfSample(
                wallNs: 5, intervalNs: 1_000_000_000, processCPUPercent: 12.5,
                systemCPUPercent: 33, residentBytes: 42, thermalState: "nominal",
                loadAverage1: 2)],
            counters: ["videoFrames": .integer(3)])
        let data = try JSONEncoder().encode(summary)
        let decoded = try JSONDecoder().decode(PerfSummary.self, from: data)
        XCTAssertEqual(decoded, summary)
    }
}
