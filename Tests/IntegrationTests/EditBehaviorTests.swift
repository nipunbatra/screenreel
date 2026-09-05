import CoreImage
import XCTest

@testable import ExportEngine
@testable import MotionEngine
@testable import PreviewEngine
@testable import ProjectModel
@testable import TimelineCore

/// Editor-facing behavior on a real project: edits persist atomically, engines
/// rebuild, regeneration never clobbers manual zooms, and disabled zooms are
/// truly inert.
final class EditBehaviorTests: XCTestCase {
    private var directory: URL!
    private var projectURL: URL!

    override func setUp() async throws {
        try await super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("screenreel-editbehavior-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        projectURL = try await SyntheticProjectFactory.make(
            in: directory, durationNs: 8_000_000_000)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    func testRegenerateZoomsPreservesManualSegments() throws {
        let composition = try ProjectComposition(projectURL: projectURL)
        XCTAssertFalse(composition.edits.zooms.isEmpty, "auto zooms expected")
        let generatedBefore = composition.edits.zooms.filter { $0.origin == "generated" }

        let manual = ZoomSegment(
            startNs: 6_000_000_000, endNs: 7_000_000_000,
            scale: 3.0, focalX: 0.9, focalY: 0.1, origin: "manual")
        try composition.updateEdits { edits in
            edits.zooms.append(manual)
            edits.zooms.sort { $0.startNs < $1.startNs }
        }
        try composition.regenerateZooms()

        let manualAfter = composition.edits.zooms.filter { $0.origin == "manual" }
        XCTAssertEqual(manualAfter, [manual], "regeneration must not touch manual zooms")
        let generatedAfter = composition.edits.zooms.filter { $0.origin == "generated" }
        XCTAssertEqual(generatedAfter.count, generatedBefore.count)

        // A fresh open sees the persisted state, not regenerated-from-scratch.
        let reopened = try ProjectComposition(projectURL: projectURL)
        XCTAssertEqual(
            reopened.edits.zooms.filter { $0.origin == "manual" }, [manual])
    }

    func testDisabledZoomLeavesCameraAtIdentity() throws {
        let composition = try ProjectComposition(projectURL: projectURL)
        guard let firstZoom = composition.edits.zooms.first else {
            return XCTFail("expected at least one zoom")
        }
        let midNs = (firstZoom.startNs + firstZoom.endNs) / 2
        XCTAssertGreaterThan(composition.cameraState(at: midNs).scale, 1.15)

        try composition.updateEdits { edits in
            for index in edits.zooms.indices {
                edits.zooms[index].disabled = true
            }
        }
        XCTAssertEqual(composition.cameraState(at: midNs).scale, 1.0, accuracy: 0.001)
    }

    func testCursorSettingChangesRebuildDeterministically() throws {
        let composition = try ProjectComposition(projectURL: projectURL)
        let probeNs: Int64 = 3_000_000_000
        let smoothed = try XCTUnwrap(composition.cursorState(at: probeNs))

        try composition.updateEdits { $0.cursor.smoothed = false }
        let raw = try XCTUnwrap(composition.cursorState(at: probeNs))
        XCTAssertEqual(
            raw.position, composition.motionTimeline.targetPosition(at: probeNs))

        try composition.updateEdits { $0.cursor.smoothed = true }
        let smoothedAgain = try XCTUnwrap(composition.cursorState(at: probeNs))
        XCTAssertEqual(smoothedAgain, smoothed, "toggling back must reproduce identical state")
    }

    func testStyledExportCancellationLeavesNoResidue() async throws {
        let outputURL = directory.appendingPathComponent("cancelled.mp4")
        try Data("existing destination".utf8).write(to: outputURL)

        let project = projectURL!
        let destination = directory.appendingPathComponent("cancelled-new.mp4")
        let exportTask = Task {
            try await StyledExporter.export(
                projectAt: project,
                to: destination,
                options: .init(fps: 30, outputHeight: 180))
        }
        try await Task.sleep(for: .milliseconds(400))
        exportTask.cancel()
        do {
            _ = try await exportTask.value
            XCTFail("expected cancellation")
        } catch {
            XCTAssertTrue(
                error is CancellationError, "expected CancellationError, got \(error)")
        }

        // No partials anywhere, destination untouched, project still healthy.
        let leftovers = try FileManager.default
            .contentsOfDirectory(atPath: directory.path)
            .filter { $0.contains(".partial") }
        XCTAssertTrue(leftovers.isEmpty, "\(leftovers)")
        XCTAssertEqual(
            try String(contentsOf: outputURL, encoding: .utf8), "existing destination")
        let report = await Validator(options: .init(verifyChecksums: true))
            .validate(projectAt: projectURL)
        XCTAssertTrue(report.isHealthy, "\(report.issues)")
    }
}
