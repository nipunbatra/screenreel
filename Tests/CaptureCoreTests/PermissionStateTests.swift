import XCTest

@testable import CaptureCore

/// The Screen Recording permission state machine, including the stale-grant
/// case that produced the endless "granted after launch" loop: Settings
/// shows the toggle on while capture keeps failing.
final class PermissionStateTests: XCTestCase {

    func testEnumerationWorkingMeansGranted() {
        XCTAssertEqual(
            ScreenPermissionState.diagnose(preflightGranted: true, displaysEnumerate: true),
            .granted)
        // Enumeration is the ground truth even if preflight lags.
        XCTAssertEqual(
            ScreenPermissionState.diagnose(preflightGranted: false, displaysEnumerate: true),
            .granted)
    }

    func testNoGrantAnywhereMeansDenied() {
        XCTAssertEqual(
            ScreenPermissionState.diagnose(preflightGranted: false, displaysEnumerate: false),
            .denied)
    }

    func testSettingsOnButCaptureFailingMeansStaleGrant() {
        XCTAssertEqual(
            ScreenPermissionState.diagnose(preflightGranted: true, displaysEnumerate: false),
            .staleGrant)
    }

    func testEveryBrokenStateHasGuidanceAndAction() {
        for state: ScreenPermissionState in [.denied, .staleGrant, .grantedAfterLaunch] {
            XCTAssertFalse(state.guidance.isEmpty, "\(state) has no guidance")
            XCTAssertFalse(state.actionTitle.isEmpty, "\(state) has no action")
        }
    }

    func testGrantedNeedsNoMessaging() {
        XCTAssertTrue(ScreenPermissionState.granted.guidance.isEmpty)
        XCTAssertTrue(ScreenPermissionState.granted.actionTitle.isEmpty)
    }

    func testStaleGuidanceNamesTheRepairAction() {
        // The button and the text must agree, or the user hunts for a
        // control the text promised.
        let state = ScreenPermissionState.staleGrant
        XCTAssertTrue(state.guidance.contains(state.actionTitle))
    }

    func testRelaunchGuidanceNamesRelaunch() {
        let state = ScreenPermissionState.grantedAfterLaunch
        XCTAssertTrue(state.guidance.contains(state.actionTitle))
    }
}
