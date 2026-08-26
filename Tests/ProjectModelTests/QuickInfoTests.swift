import Foundation
import XCTest

@testable import ProjectModel

/// ProjectQuickInfo reads project-card metadata from manifest.json alone —
/// never the journal — so browsers stay fast, and JSONValue's numeric
/// accessor handles both integer- and double-encoded values.
final class QuickInfoTests: XCTestCase {

    private var root: URL!

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("aks-quickinfo-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    func testReadsDurationAndStateFromManifestOnly() throws {
        let projectURL = root.appendingPathComponent("p.aks")
        let layout = ProjectLayout(root: projectURL)
        try FileManager.default.createDirectory(
            at: projectURL, withIntermediateDirectories: true)
        var manifest = Manifest(
            state: .ready,
            clock: ClockAnchor(
                originContinuousTicks: 0, originAbsoluteTicks: 0,
                timebaseNumer: 1, timebaseDenom: 1,
                originWallTime: RFC3339.now()))
        manifest.durationNs = 42_000_000_000
        try AtomicFile.writeJSON(manifest, to: layout.manifestURL)
        // Deliberately NO journal file: quick info must not need one.

        let info = try XCTUnwrap(ProjectQuickInfo.read(at: projectURL))
        XCTAssertEqual(info.durationNs, 42_000_000_000)
        XCTAssertEqual(info.state, .ready)
    }

    func testMissingManifestYieldsNil() {
        let projectURL = root.appendingPathComponent("empty.aks")
        try? FileManager.default.createDirectory(
            at: projectURL, withIntermediateDirectories: true)
        XCTAssertNil(ProjectQuickInfo.read(at: projectURL))
    }

    func testCorruptManifestYieldsNilNotCrash() throws {
        let projectURL = root.appendingPathComponent("bad.aks")
        let layout = ProjectLayout(root: projectURL)
        try FileManager.default.createDirectory(
            at: projectURL, withIntermediateDirectories: true)
        try Data("{{{{".utf8).write(to: layout.manifestURL)
        XCTAssertNil(ProjectQuickInfo.read(at: projectURL))
    }

    // MARK: JSONValue numeric accessor

    func testDoubleValueReadsBothNumericEncodings() {
        XCTAssertEqual(JSONValue.double(12.5).doubleValue, 12.5)
        // Whole doubles canonicalize to integers; the accessor bridges back.
        XCTAssertEqual(JSONValue.integer(40).doubleValue, 40.0)
    }

    func testDoubleValueRejectsNonNumerics() {
        XCTAssertNil(JSONValue.string("40").doubleValue)
        XCTAssertNil(JSONValue.bool(true).doubleValue)
        XCTAssertNil(JSONValue.null.doubleValue)
    }

    func testDoubleValueThroughDecodedCaptureJSON() throws {
        // The exact path ProjectComposition uses to read event offsets.
        let json = try JSONValue(encoding: ["eventOffsetXPx": 12.5, "eventOffsetYPx": 7.0])
        XCTAssertEqual(json["eventOffsetXPx"]?.doubleValue, 12.5)
        XCTAssertEqual(json["eventOffsetYPx"]?.doubleValue, 7.0)
        XCTAssertNil(json["missing"]?.doubleValue)
    }
}
