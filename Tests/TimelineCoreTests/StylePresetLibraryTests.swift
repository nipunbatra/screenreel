import Foundation
import XCTest

@testable import TimelineCore

/// Style preset persistence: upsert-by-name, sorted listing, resilient
/// loading, and atomic save.
final class StylePresetLibraryTests: XCTestCase {

    private var fileURL: URL!

    override func setUp() {
        super.setUp()
        fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("aks-presets-\(UUID().uuidString)")
            .appendingPathComponent("style-presets.json")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(
            at: fileURL.deletingLastPathComponent())
        super.tearDown()
    }

    private func preset(_ name: String, padding: Double = 0.05) -> StylePreset {
        StylePreset(name: name, style: FrameStyle(padding: padding))
    }

    func testRoundTripThroughDisk() throws {
        var library = StylePresetLibrary()
        library.upsert(preset("CS 203", padding: 0.08))
        library.upsert(preset("Lab talks"))
        try library.save(to: fileURL)

        let loaded = StylePresetLibrary.load(from: fileURL)
        XCTAssertEqual(loaded, library)
        XCTAssertEqual(loaded.presets.count, 2)
        XCTAssertEqual(
            loaded.presets.first(where: { $0.name == "CS 203" })?.style.padding, 0.08)
    }

    func testUpsertReplacesByName() {
        var library = StylePresetLibrary()
        library.upsert(preset("CS 203", padding: 0.05))
        library.upsert(preset("CS 203", padding: 0.12))
        XCTAssertEqual(library.presets.count, 1)
        XCTAssertEqual(library.presets[0].style.padding, 0.12)
    }

    func testPresetsStaySortedByName() {
        var library = StylePresetLibrary()
        library.upsert(preset("zeta"))
        library.upsert(preset("Alpha"))
        library.upsert(preset("m course"))
        XCTAssertEqual(library.presets.map(\.name), ["Alpha", "m course", "zeta"])
    }

    func testRemoveByName() {
        var library = StylePresetLibrary()
        library.upsert(preset("a"))
        library.upsert(preset("b"))
        library.remove(named: "a")
        XCTAssertEqual(library.presets.map(\.name), ["b"])
        // Removing a missing name is a no-op, not a crash.
        library.remove(named: "ghost")
        XCTAssertEqual(library.presets.count, 1)
    }

    func testMissingFileLoadsEmpty() {
        let loaded = StylePresetLibrary.load(
            from: fileURL.deletingLastPathComponent().appendingPathComponent("nope.json"))
        XCTAssertTrue(loaded.presets.isEmpty)
    }

    func testCorruptFileLoadsEmptyInsteadOfCrashing() throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not json at all {{{".utf8).write(to: fileURL)
        let loaded = StylePresetLibrary.load(from: fileURL)
        XCTAssertTrue(loaded.presets.isEmpty)
    }

    func testPresetCarriesCameraAndCursorStyling() throws {
        var library = StylePresetLibrary()
        var preset = preset("With camera")
        preset.camera = CameraStyle(corner: .topLeft, shape: .circle)
        preset.cursor = CursorSettings(sizeMultiplier: 2)
        library.upsert(preset)
        try library.save(to: fileURL)
        let loaded = StylePresetLibrary.load(from: fileURL)
        XCTAssertEqual(loaded.presets[0].camera.corner, .topLeft)
        XCTAssertEqual(loaded.presets[0].camera.shape, .circle)
        XCTAssertEqual(loaded.presets[0].cursor.sizeMultiplier, 2)
    }
}
