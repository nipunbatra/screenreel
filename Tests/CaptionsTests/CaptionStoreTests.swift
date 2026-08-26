import Foundation
import ProjectModel
import XCTest

@testable import Captions

/// Caption persistence: atomic sidecar in edits/, missing-file tolerance,
/// corrupt-file preserve-aside, and raw-media isolation.
final class CaptionStoreTests: XCTestCase {

    private var layout: ProjectLayout!

    override func setUpWithError() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("captionstore-\(UUID().uuidString).aks")
        layout = ProjectLayout(root: root)
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: layout.root)
    }

    func testMissingFileLoadsEmpty() throws {
        XCTAssertEqual(try CaptionStore.load(from: layout), [])
    }

    func testRoundTripPreservesCuesExactly() throws {
        let cues = [
            CaptionCue(startNs: 0, endNs: 1_500_000_000, text: "Hello there"),
            CaptionCue(startNs: 2_000_000_000, endNs: 4_000_000_000, text: "Second cue — dashes, émojis 🎬"),
        ]
        try CaptionStore.save(cues, to: layout)
        XCTAssertEqual(try CaptionStore.load(from: layout), cues)
        // Lives in edits/, never anywhere near raw media.
        XCTAssertTrue(
            CaptionStore.url(in: layout).path.contains("/edits/"))
        XCTAssertFalse(
            CaptionStore.url(in: layout).path.contains("/raw/"))
    }

    func testSaveOverwritesAtomically() throws {
        try CaptionStore.save(
            [CaptionCue(startNs: 0, endNs: 1, text: "old")], to: layout)
        let next = [CaptionCue(startNs: 5, endNs: 9, text: "new")]
        try CaptionStore.save(next, to: layout)
        XCTAssertEqual(try CaptionStore.load(from: layout), next)
    }

    func testCorruptFileIsPreservedAsideAndThrows() throws {
        try FileManager.default.createDirectory(
            at: layout.editsDirectory, withIntermediateDirectories: true)
        let url = CaptionStore.url(in: layout)
        try Data("{not json".utf8).write(to: url)

        XCTAssertThrowsError(try CaptionStore.load(from: layout))
        // Original bytes preserved under a corrupt-* aside, slot cleared.
        let siblings = try FileManager.default.contentsOfDirectory(
            at: layout.editsDirectory, includingPropertiesForKeys: nil)
        XCTAssertTrue(
            siblings.contains { $0.lastPathComponent.hasPrefix("captions.corrupt-") },
            "corrupt sidecar must be preserved aside, found: \(siblings)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        // Next load starts clean.
        XCTAssertEqual(try CaptionStore.load(from: layout), [])
    }

    func testEmptyCueListRoundTrips() throws {
        try CaptionStore.save([], to: layout)
        XCTAssertEqual(try CaptionStore.load(from: layout), [])
    }
}
