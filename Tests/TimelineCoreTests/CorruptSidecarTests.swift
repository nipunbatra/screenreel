import XCTest

@testable import ProjectModel
@testable import TimelineCore

/// Corrupt sidecar files (edit document, style presets) are moved aside as
/// `<name>.corrupt-<timestamp>` before any error or empty fallback — the
/// original bytes must survive for forensics, and no later save may
/// overwrite them (a corrupt store is never overwritten).
final class CorruptSidecarTests: XCTestCase {
    private var directory: URL!
    private var layout: ProjectLayout!

    override func setUp() {
        super.setUp()
        AtomicFile.fullFsync = false
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("screenreel-corrupt-\(UUID().uuidString).screenreel")
        layout = ProjectLayout(root: directory)
        try? FileManager.default.createDirectory(
            at: layout.editsDirectory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        AtomicFile.fullFsync = true
        super.tearDown()
    }

    private func editsEntries() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: layout.editsDirectory.path)
    }

    func testCorruptTimelineIsPreservedAsideAndThrows() throws {
        let original = Data("{\"style\": definitely not json".utf8)
        try original.write(to: EditDocument.url(in: layout))

        XCTAssertThrowsError(try EditDocument.load(from: layout))

        // The corrupt file was moved aside — original path gone, forensic
        // copy holds the exact original bytes.
        let entries = try editsEntries()
        XCTAssertFalse(entries.contains("timeline.json"), "\(entries)")
        let preserved = entries.filter { $0.hasPrefix("timeline.json.corrupt-") }
        XCTAssertEqual(preserved.count, 1, "\(entries)")
        XCTAssertEqual(
            try Data(contentsOf: layout.editsDirectory.appendingPathComponent(preserved[0])),
            original)

        // With the evidence out of the way, a fresh load yields defaults and
        // a save can no longer destroy the corrupt document.
        XCTAssertEqual(try EditDocument.load(from: layout), EditDocument())
        try EditDocument().save(to: layout)
        XCTAssertEqual(
            try Data(contentsOf: layout.editsDirectory.appendingPathComponent(preserved[0])),
            original)
    }

    func testNewerSchemaDocumentIsNotTreatedAsCorrupt() throws {
        // A valid document from a newer build is data, not corruption: it is
        // rejected actionably and stays exactly where it is.
        var document = EditDocument()
        document.schemaVersion = 99
        try JSONEncoder().encode(document).write(to: EditDocument.url(in: layout))

        XCTAssertThrowsError(try EditDocument.load(from: layout)) { error in
            guard case ScreenreelError.schemaTooNew = error else {
                return XCTFail("expected schemaTooNew, got \(error)")
            }
        }
        let entries = try editsEntries()
        XCTAssertTrue(entries.contains("timeline.json"))
        XCTAssertTrue(entries.filter { $0.contains(".corrupt-") }.isEmpty, "\(entries)")
    }

    func testRepeatedCorruptionKeepsEveryForensicCopy() throws {
        let first = Data("corrupt one".utf8)
        try first.write(to: EditDocument.url(in: layout))
        XCTAssertThrowsError(try EditDocument.load(from: layout))

        let second = Data("corrupt two, different bytes".utf8)
        try second.write(to: EditDocument.url(in: layout))
        XCTAssertThrowsError(try EditDocument.load(from: layout))

        let preserved = try editsEntries()
            .filter { $0.hasPrefix("timeline.json.corrupt-") }
            .sorted()
        XCTAssertEqual(preserved.count, 2, "\(preserved)")
        let bytes = try Set(preserved.map {
            try Data(contentsOf: layout.editsDirectory.appendingPathComponent($0))
        })
        XCTAssertEqual(bytes, [first, second])
    }

    func testCorruptPresetsLoadEmptyAndPreserveBytes() throws {
        let presetsURL = directory.appendingPathComponent("style-presets.json")
        let original = Data("not json at all {{{".utf8)
        try original.write(to: presetsURL)

        let loaded = StylePresetLibrary.load(from: presetsURL)
        XCTAssertTrue(loaded.presets.isEmpty)

        let entries = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertFalse(entries.contains("style-presets.json"), "\(entries)")
        let preserved = entries.filter { $0.hasPrefix("style-presets.json.corrupt-") }
        XCTAssertEqual(preserved.count, 1, "\(entries)")
        XCTAssertEqual(
            try Data(contentsOf: directory.appendingPathComponent(preserved[0])),
            original)

        // Saving a fresh library recreates the canonical file without
        // touching the forensic copy.
        var library = StylePresetLibrary()
        library.upsert(StylePreset(name: "Fresh", style: FrameStyle()))
        try library.save(to: presetsURL)
        XCTAssertEqual(StylePresetLibrary.load(from: presetsURL).presets.count, 1)
        XCTAssertEqual(
            try Data(contentsOf: directory.appendingPathComponent(preserved[0])),
            original)
    }

    func testMissingPresetsFileIsNotPreservedAside() {
        let missing = directory.appendingPathComponent("nope.json")
        XCTAssertTrue(StylePresetLibrary.load(from: missing).presets.isEmpty)
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        XCTAssertTrue(entries.filter { $0.contains(".corrupt-") }.isEmpty, "\(entries)")
    }
}
