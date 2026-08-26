import XCTest

@testable import ProjectModel

/// Every released schema version keeps a checked-in fixture project that
/// current code must read forever (`docs/PROJECT_FORMAT.md` §8). The fixture
/// lives next to this file and uses byte-sized fake media so it stays small.
///
/// Regenerate (only when introducing a NEW schema version, never to “fix” a
/// failing test): AKS_REGENERATE_FIXTURES=1 swift test --filter SchemaFixtureTests
final class SchemaFixtureTests: XCTestCase {
    private static var fixturesRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures")
    }

    private var v1URL: URL {
        Self.fixturesRoot.appendingPathComponent("v1/fixture-v1.aks")
    }

    override func setUp() {
        super.setUp()
        AtomicFile.fullFsync = false
    }

    override func tearDown() {
        AtomicFile.fullFsync = true
        super.tearDown()
    }

    func testGenerateFixtureIfRequested() async throws {
        guard ProcessInfo.processInfo.environment["AKS_REGENERATE_FIXTURES"] == "1" else {
            throw XCTSkip("set AKS_REGENERATE_FIXTURES=1 to (re)generate")
        }
        try? FileManager.default.removeItem(at: v1URL)
        try FileManager.default.createDirectory(
            at: v1URL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try await TestProject.build(at: v1URL)
        // Derived/jobs/diagnostics stay empty; drop them so the fixture is
        // only the format-bearing files.
        for name in ["derived", "jobs", "diagnostics", ".history"] {
            try? FileManager.default.removeItem(at: v1URL.appendingPathComponent(name))
        }
    }

    func testV1FixtureRemainsReadable() async throws {
        guard FileManager.default.fileExists(atPath: v1URL.path) else {
            throw XCTSkip("fixture not generated yet")
        }
        let loaded = try ProjectPackage.load(at: v1URL)
        XCTAssertEqual(loaded.manifest.schemaVersion, 1)
        XCTAssertEqual(loaded.manifest.state, .ready)
        XCTAssertNil(loaded.journal.truncationReason)
        XCTAssertTrue(loaded.journal.isFinalized)
        XCTAssertEqual(loaded.manifest.tracks.count, 3)

        let report = await Validator().validate(projectAt: v1URL)
        XCTAssertTrue(report.isHealthy, "\(report.issues)")
    }

    func testV1FixtureEventChunkParses() throws {
        let chunkURL = v1URL.appendingPathComponent("events/cursor-000001.jsonl")
        guard let data = try? Data(contentsOf: chunkURL) else {
            throw XCTSkip("fixture not generated yet")
        }
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        var lineNumber = 0
        for line in text.split(separator: "\n") {
            lineNumber += 1
            let record = try EventRecord.parse(line: line, lineNumber: lineNumber)
            XCTAssertEqual(record.schemaVersion, 1)
            XCTAssertTrue(record.structuralProblems().isEmpty)
        }
        XCTAssertEqual(lineNumber, 3)
    }
}
