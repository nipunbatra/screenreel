import XCTest

@testable import AppSupport

final class RecordingsFolderTests: XCTestCase {
    private var movies: URL!

    override func setUp() {
        super.setUp()
        movies = FileManager.default.temporaryDirectory
            .appendingPathComponent("screenreel-movies-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: movies, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: movies)
        super.tearDown()
    }

    private func make(_ name: String, files: [String] = []) throws -> URL {
        let url = movies.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        for file in files {
            try Data(file.utf8).write(to: url.appendingPathComponent(file))
        }
        return url
    }

    func testLegacyFolderIsRenamedWithItsContents() throws {
        _ = try make("Aks", files: ["Recording 1.aks", "Recording 2.aks"])
        let result = RecordingsFolder.resolveDefault(in: movies)
        XCTAssertEqual(result.migration, .moved)
        XCTAssertEqual(result.url.lastPathComponent, "Screenreel")
        XCTAssertFalse(FileManager.default.fileExists(atPath: movies.appendingPathComponent("Aks").path))
        let contents = try FileManager.default.contentsOfDirectory(atPath: result.url.path).sorted()
        XCTAssertEqual(contents, ["Recording 1.aks", "Recording 2.aks"])
        // Second launch: nothing more to do.
        XCTAssertEqual(RecordingsFolder.resolveDefault(in: movies).migration, .none)
    }

    func testBothFoldersPresentLeavesTheLegacyOneAlone() throws {
        _ = try make("Aks", files: ["old.aks"])
        _ = try make("Screenreel", files: ["new.screenreel"])
        let result = RecordingsFolder.resolveDefault(in: movies)
        XCTAssertEqual(result.migration, .keptBoth)
        XCTAssertEqual(result.url.lastPathComponent, "Screenreel")
        XCTAssertTrue(FileManager.default.fileExists(atPath: movies.appendingPathComponent("Aks/old.aks").path))
    }

    func testFreshInstallNeedsNoMigration() {
        let result = RecordingsFolder.resolveDefault(in: movies)
        XCTAssertEqual(result.migration, .none)
        XCTAssertEqual(result.url.lastPathComponent, "Screenreel")
        XCTAssertFalse(FileManager.default.fileExists(atPath: result.url.path), "resolution must not create folders")
    }

    func testFailedRenameFallsBackToTheLegacyFolder() throws {
        let legacy = try make("Aks", files: ["old.aks"])
        // A file where the new folder should go makes the rename fail.
        try Data("x".utf8).write(to: movies.appendingPathComponent("Screenreel"))
        let result = RecordingsFolder.resolveDefault(in: movies)
        if case .failed = result.migration {} else { XCTFail("expected .failed, got \(result.migration)") }
        XCTAssertEqual(result.url, legacy)
    }
}
