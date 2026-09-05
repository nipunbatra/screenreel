import XCTest

@testable import ScreenreelCLI
@testable import ProjectModel

/// In-process run of the `screenreel selftest` measurement core: record a 10 s flash/beep marker session through the real
/// pipeline, decode it back, and assert the measured A/V numbers meet the
/// selftest's own shipping thresholds.
final class SelftestTests: XCTestCase {
    private var directory: URL!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("screenreel-selftest-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    func testTenSecondMarkerRunMeetsSyncThresholds() async throws {
        let projectURL = directory.appendingPathComponent("selftest.screenreel")
        // pace 4 compresses the wall clock; marker timestamps live on the
        // session clock, so the measured sync numbers are pace-independent.
        let markers = try await SyncSelftest.record(
            projectURL: projectURL, durationNs: 10_000_000_000, pace: 4)
        XCTAssertEqual(markers, [
            1_000_000_000, 3_000_000_000, 5_000_000_000, 7_000_000_000, 9_000_000_000,
        ])

        let report = try await SyncSelftest.measure(projectAt: projectURL)
        XCTAssertEqual(report.flashOnsets, markers.count, "flash detection missed markers")
        XCTAssertEqual(report.beepOnsets, markers.count, "beep detection missed markers")
        XCTAssertEqual(report.pairs, markers.count)
        XCTAssertLessThan(
            abs(report.medianOffsetMs), report.offsetThresholdMs,
            "median A/V offset \(report.medianOffsetMs) ms: \(report.pairDetails)")
        XCTAssertLessThan(
            abs(report.driftMsPerMinute), report.driftThresholdMsPerMinute,
            "drift \(report.driftMsPerMinute) ms/min: \(report.pairDetails)")
        XCTAssertTrue(report.passed)
        // Aligned markers must not be discarded by the outlier gate.
        XCTAssertLessThanOrEqual(report.outliersRejected, 1, "\(report.pairDetails)")
    }

    /// The statistics helpers behave like the spec says: median is robust,
    /// the slope recovers a constructed drift, and MAD rejection drops a
    /// planted outlier without touching honest samples.
    func testMeasurementStatistics() {
        XCTAssertEqual(SyncSelftest.median([3, 1, 2]), 2)
        XCTAssertEqual(SyncSelftest.median([4, 1, 2, 3]), 2.5)

        // offset(t) = 10 ms + 30 ms/min · t
        let points: [(timeMin: Double, offsetMs: Double)] = [
            (0.0, 10.0), (0.05, 11.5), (0.10, 13.0), (0.15, 14.5),
        ]
        XCTAssertEqual(SyncSelftest.leastSquaresSlope(points), 30, accuracy: 0.001)
        XCTAssertEqual(SyncSelftest.leastSquaresSlope([(0.0, 5.0)]), 0)
    }
}
