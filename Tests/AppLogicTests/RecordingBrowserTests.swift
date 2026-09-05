import XCTest

@testable import AppSupport

final class RecordingBrowserTests: XCTestCase {
    private let old = Date(timeIntervalSinceNow: -3600)

    func testEmptyStaleRecordingPackageIsAFailedStart() {
        XCTAssertTrue(RecordingBrowser.isFailedStart(
            state: "recording", durationNs: nil, hasScreenMedia: false, modified: old))
        XCTAssertTrue(RecordingBrowser.isFailedStart(
            state: nil, durationNs: 0, hasScreenMedia: false, modified: old))
    }

    func testAnythingWithMediaDurationOrACleanStopIsKept() {
        XCTAssertFalse(RecordingBrowser.isFailedStart(
            state: "ready", durationNs: nil, hasScreenMedia: false, modified: old))
        XCTAssertFalse(RecordingBrowser.isFailedStart(
            state: "recoverable", durationNs: nil, hasScreenMedia: false, modified: old))
        XCTAssertFalse(RecordingBrowser.isFailedStart(
            state: "recording", durationNs: 5_000_000_000, hasScreenMedia: false, modified: old))
        XCTAssertFalse(RecordingBrowser.isFailedStart(
            state: "recording", durationNs: nil, hasScreenMedia: true, modified: old))
    }

    func testTheSessionInProgressIsNeverAFailedStart() {
        XCTAssertFalse(RecordingBrowser.isFailedStart(
            state: "recording", durationNs: nil, hasScreenMedia: false,
            modified: Date(timeIntervalSinceNow: -10)))
    }
}
