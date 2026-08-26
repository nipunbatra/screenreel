import XCTest

@testable import ProjectModel
@testable import TimelineCore

final class EditDocumentTests: XCTestCase {
    private var directory: URL!
    private var layout: ProjectLayout!

    override func setUp() {
        super.setUp()
        AtomicFile.fullFsync = false
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("aks-edits-\(UUID().uuidString).aks")
        layout = ProjectLayout(root: directory)
        try? FileManager.default.createDirectory(
            at: layout.editsDirectory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        AtomicFile.fullFsync = true
        super.tearDown()
    }

    func testMissingFileYieldsDefaults() throws {
        let document = try EditDocument.load(from: layout)
        XCTAssertEqual(document, EditDocument())
        XCTAssertTrue(document.autoZoomEnabled)
        XCTAssertTrue(document.cursor.showCursor)
        XCTAssertNil(document.trimStartNs)
    }

    func testFullRoundTrip() throws {
        var document = EditDocument()
        document.style.background = .solid(.init(red: 0.1, green: 0.2, blue: 0.3, alpha: 0.9))
        document.style.padding = 0.11
        document.style.cornerRadius = 0.04
        document.style.shadowOpacity = 0.8
        document.cursor.smoothed = false
        document.cursor.sizeMultiplier = 2.5
        document.cursor.idleHideAfterNs = 3_000_000_000
        document.cursor.heldSpring = SpringParameters(stiffness: 900, damping: 35, mass: 1.5)
        document.zooms = [
            ZoomSegment(
                startNs: 1_000_000_000, endNs: 4_000_000_000, scale: 3.2,
                focalX: 0.2, focalY: 0.8, instant: true,
                origin: "generated", generatorVersion: 1),
            ZoomSegment(startNs: 6_000_000_000, endNs: 7_000_000_000, disabled: true),
        ]
        document.autoZoomEnabled = false
        document.trimStartNs = 500_000_000
        document.trimEndNs = 9_000_000_000

        try document.save(to: layout)
        let loaded = try EditDocument.load(from: layout)
        XCTAssertEqual(loaded, document)

        // Gradient and none variants also round-trip.
        for background: FrameStyle.Background in [
            .none,
            .linearGradient(top: .white, bottom: .black),
        ] {
            document.style.background = background
            try document.save(to: layout)
            XCTAssertEqual(try EditDocument.load(from: layout).style.background, background)
        }
    }

    func testAtomicSaveLeavesNoTemporaries() throws {
        var document = EditDocument()
        for index in 0..<5 {
            document.style.padding = Double(index) / 100
            try document.save(to: layout)
        }
        let leftovers = try FileManager.default
            .contentsOfDirectory(atPath: layout.editsDirectory.path)
            .filter { $0.contains(".tmp") }
        XCTAssertTrue(leftovers.isEmpty)
    }

    func testNewerSchemaIsRejectedActionably() throws {
        var document = EditDocument()
        document.schemaVersion = 99
        let encoder = JSONEncoder()
        try encoder.encode(document).write(to: EditDocument.url(in: layout))
        XCTAssertThrowsError(try EditDocument.load(from: layout)) { error in
            guard case AksError.schemaTooNew(let found, _, _) = error else {
                return XCTFail("expected schemaTooNew, got \(error)")
            }
            XCTAssertEqual(found, 99)
        }
    }

    func testCorruptDocumentThrowsRatherThanSilentlyDefaulting() throws {
        try Data("not json at all".utf8).write(to: EditDocument.url(in: layout))
        XCTAssertThrowsError(try EditDocument.load(from: layout))
    }

    func testCanvasAspectRoundTripIncludingNil() throws {
        var document = EditDocument()
        for aspect: Double? in [nil, 16.0 / 9.0, 9.0 / 16.0, 1.0] {
            document.style.canvasAspect = aspect
            try document.save(to: layout)
            XCTAssertEqual(try EditDocument.load(from: layout).style.canvasAspect, aspect)
        }
        // Documents written before the field existed still decode (nil).
        var legacy = try JSONSerialization.jsonObject(
            with: Data(contentsOf: EditDocument.url(in: layout))) as! [String: Any]
        var style = legacy["style"] as! [String: Any]
        style.removeValue(forKey: "canvasAspect")
        legacy["style"] = style
        try JSONSerialization.data(withJSONObject: legacy)
            .write(to: EditDocument.url(in: layout))
        XCTAssertNil(try EditDocument.load(from: layout).style.canvasAspect)
    }
}

/// Timeline drag-edit math: pure, clamped, and safe under hostile input.
final class ZoomDragMathTests: XCTestCase {
    private let duration: Int64 = 10_000_000_000

    private func zoom(_ start: Int64, _ end: Int64) -> ZoomSegment {
        ZoomSegment(startNs: start, endNs: end)
    }

    func testMovePreservesLengthAndClamps() {
        let original = zoom(2_000_000_000, 4_000_000_000)
        let forward = original.moved(byNs: 1_000_000_000, durationNs: duration)
        XCTAssertEqual(forward.startNs, 3_000_000_000)
        XCTAssertEqual(forward.endNs - forward.startNs, 2_000_000_000)

        let pastEnd = original.moved(byNs: 100_000_000_000, durationNs: duration)
        XCTAssertEqual(pastEnd.endNs, duration)
        XCTAssertEqual(pastEnd.endNs - pastEnd.startNs, 2_000_000_000)

        let pastStart = original.moved(byNs: -100_000_000_000, durationNs: duration)
        XCTAssertEqual(pastStart.startNs, 0)
        XCTAssertEqual(pastStart.endNs - pastStart.startNs, 2_000_000_000)
    }

    func testResizeHonorsMinimumLength() {
        let original = zoom(2_000_000_000, 4_000_000_000)
        let collapsedFromStart = original.resizingStart(byNs: 100_000_000_000)
        XCTAssertEqual(collapsedFromStart.startNs, 4_000_000_000 - ZoomSegment.minLengthNs)
        let collapsedFromEnd = original.resizingEnd(byNs: -100_000_000_000, durationNs: duration)
        XCTAssertEqual(collapsedFromEnd.endNs, 2_000_000_000 + ZoomSegment.minLengthNs)
        // Resizing never crosses [0, duration].
        XCTAssertEqual(original.resizingStart(byNs: -100_000_000_000).startNs, 0)
        XCTAssertEqual(
            original.resizingEnd(byNs: 100_000_000_000, durationNs: duration).endNs, duration)
    }

    func testHostileOverlongSegmentShrinksToFit() {
        let hostile = ZoomSegment(startNs: 0, endNs: 50_000_000_000)
        let moved = hostile.moved(byNs: 1_000_000_000, durationNs: duration)
        XCTAssertGreaterThanOrEqual(moved.startNs, 0)
        XCTAssertLessThanOrEqual(moved.endNs, duration)
        XCTAssertGreaterThanOrEqual(moved.endNs - moved.startNs, ZoomSegment.minLengthNs)
    }

    func testDragFuzzInvariants() {
        // Deterministic LCG so every failure reproduces.
        var state: UInt64 = 0x1234_5678
        func nextInt64(in range: ClosedRange<Int64>) -> Int64 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            let span = UInt64(range.upperBound - range.lowerBound)
            return range.lowerBound + Int64(state % (span + 1))
        }
        var segment = zoom(3_000_000_000, 6_000_000_000)
        for step in 0..<5000 {
            let delta = nextInt64(in: -20_000_000_000...20_000_000_000)
            switch step % 3 {
            case 0: segment = segment.moved(byNs: delta, durationNs: duration)
            case 1: segment = segment.resizingStart(byNs: delta)
            default: segment = segment.resizingEnd(byNs: delta, durationNs: duration)
            }
            XCTAssertGreaterThanOrEqual(segment.startNs, 0, "step \(step)")
            XCTAssertLessThanOrEqual(segment.endNs, duration, "step \(step)")
            XCTAssertGreaterThanOrEqual(
                segment.endNs - segment.startNs, ZoomSegment.minLengthNs, "step \(step)")
        }
    }
}

extension EditDocumentTests {
    /// clickRipples is optional-with-default: absent → enabled, explicit
    /// false round-trips.
    func testClickRipplesDefaultOnAndRoundTrip() throws {
        XCTAssertTrue(CursorSettings().clickRipplesEnabled)

        // A pre-clickRipples document: every old field present, the new
        // key absent (encoding a default omits the nil optional — exactly
        // the legacy shape).
        let legacyData = try JSONEncoder().encode(CursorSettings())
        XCTAssertFalse(
            String(decoding: legacyData, as: UTF8.self).contains("clickRipples"))
        let decoded = try JSONDecoder().decode(CursorSettings.self, from: legacyData)
        XCTAssertTrue(decoded.clickRipplesEnabled)

        var settings = CursorSettings()
        settings.clickRipples = false
        let redecoded = try JSONDecoder().decode(
            CursorSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertFalse(redecoded.clickRipplesEnabled)
    }
}
