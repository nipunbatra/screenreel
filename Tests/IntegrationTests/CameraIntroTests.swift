import Foundation
import TimelineCore
import XCTest

@testable import PreviewEngine

/// The camera-intro time mapping: hold at 0 through the intro, cubic
/// ease-out to 1 over 600 ms, anchored at the trimmed range start so the
/// EXPORTED first frame is the fullscreen opening.
final class CameraIntroTests: XCTestCase {

    private var directory: URL!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("screenreel-intro-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    func testProgressHoldsThenEasesAndAnchorsAtTrimStart() async throws {
        let projectURL = try await SyntheticProjectFactory.make(
            in: directory, durationNs: 9_000_000_000)
        let composition = try ProjectComposition(projectURL: projectURL)

        // No intro → always 1.
        XCTAssertEqual(composition.cameraIntroProgress(atOutput: 0), 1)

        try composition.updateEdits { edits in
            edits.camera.introNs = 3_000_000_000
        }
        // Hold fullscreen through the intro…
        XCTAssertEqual(composition.cameraIntroProgress(atOutput: 0), 0)
        XCTAssertEqual(
            composition.cameraIntroProgress(atOutput: 2_999_999_999), 0)
        // …ease monotonically over the next 600 ms…
        let quarter = composition.cameraIntroProgress(atOutput: 3_150_000_000)
        let half = composition.cameraIntroProgress(atOutput: 3_300_000_000)
        XCTAssertGreaterThan(quarter, 0)
        XCTAssertGreaterThan(half, quarter)
        XCTAssertLessThan(half, 1)
        // …and settle at exactly 1.
        XCTAssertEqual(
            composition.cameraIntroProgress(atOutput: 3_600_000_000), 1)
        XCTAssertEqual(
            composition.cameraIntroProgress(atOutput: 8_000_000_000), 1)

        // Trim 2 s off the head: the intro re-anchors to the exported
        // opening, not wall-clock zero. 7 s remain, so the hold clamps to
        // min(3 s, 7/2 − 0.6 s) = 2.9 s → fullscreen through 4.9 s,
        // settled by 5.5 s.
        try composition.updateEdits { edits in
            edits.trimStartNs = 2_000_000_000
        }
        XCTAssertEqual(
            composition.cameraIntroProgress(atOutput: 2_000_000_000), 0)
        XCTAssertEqual(
            composition.cameraIntroProgress(atOutput: 4_899_999_999), 0)
        XCTAssertGreaterThan(
            composition.cameraIntroProgress(atOutput: 4_950_000_000), 0)
        XCTAssertEqual(
            composition.cameraIntroProgress(atOutput: 5_500_000_000), 1)
    }

    /// The hold may consume at most HALF the playable range: trimming a
    /// recording down to a short tail can never leave an all-camera export
    /// with the screen content unreachable.
    func testIntroLongerThanRangeStillShowsScreenContent() async throws {
        let projectURL = try await SyntheticProjectFactory.make(
            in: directory, durationNs: 9_000_000_000)
        let composition = try ProjectComposition(projectURL: projectURL)
        try composition.updateEdits { edits in
            edits.camera.introNs = 10_000_000_000  // longer than the range
            edits.trimStartNs = 6_000_000_000  // 3 s tail remains
        }
        // Hold = min(10 s, 3/2 − 0.6 s) = 0.9 s: fullscreen at the anchor…
        XCTAssertEqual(
            composition.cameraIntroProgress(atOutput: 6_000_000_000), 0)
        XCTAssertEqual(
            composition.cameraIntroProgress(atOutput: 6_800_000_000), 0)
        // …and fully settled on screen content well before the range ends.
        XCTAssertEqual(
            composition.cameraIntroProgress(atOutput: 7_500_000_000), 1)
        XCTAssertEqual(
            composition.cameraIntroProgress(atOutput: 8_900_000_000), 1)
    }
}
