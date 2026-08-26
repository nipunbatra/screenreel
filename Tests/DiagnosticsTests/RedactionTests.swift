import XCTest

@testable import Diagnostics
@testable import ProjectModel

/// Diagnostic reports must be shareable: home directories and URL query
/// values disappear from every string leaf while the report stays valid,
/// round-trippable JSON, and corrupt log entries are skipped, not fatal.
final class RedactionTests: XCTestCase {

    // MARK: - String rules

    func testHomeDirectoryBecomesTilde() {
        XCTAssertEqual(
            Redaction.redact("/Users/alice/git/aks/Project.aks"),
            "~/git/aks/Project.aks")
        XCTAssertEqual(Redaction.redact("/Users/alice"), "~")
        // Any user, every occurrence, mid-sentence.
        XCTAssertEqual(
            Redaction.redact("copied /Users/alice/a.mov over /Users/bob-2/b.mov"),
            "copied ~/a.mov over ~/b.mov")
        // Non-home paths survive untouched.
        XCTAssertEqual(
            Redaction.redact("/tmp/aks/raw/screen/display-1-000001.mov"),
            "/tmp/aks/raw/screen/display-1-000001.mov")
    }

    func testURLQueryValuesAreElidedButKeysSurvive() {
        XCTAssertEqual(
            Redaction.redact("https://api.example.com/upload?token=s3cr3t&sig=abc123"),
            "https://api.example.com/upload?token=…&sig=…")
        // Empty values elide too; paths without queries are untouched.
        XCTAssertEqual(
            Redaction.redact("https://example.com/health?probe="),
            "https://example.com/health?probe=…")
        XCTAssertEqual(
            Redaction.redact("https://example.com/plain/path"),
            "https://example.com/plain/path")
    }

    func testHomeInsideURLQueryIsDoublyRedacted() {
        XCTAssertEqual(
            Redaction.redact("app://open?path=/Users/alice/Movies/demo.aks"),
            "app://open?path=…")
    }

    // MARK: - JSON leaves

    func testNestedLeavesRedactedAndNonStringsUntouched() throws {
        let value = JSONValue.object([
            "path": .string("/Users/alice/Movies/p.aks"),
            "count": .integer(3),
            "ratio": .double(1.5),
            "ok": .bool(true),
            "missing": .null,
            "nested": .object([
                "url": .string("https://x.test/a?key=v"),
                "list": .array([.string("/Users/carol/x"), .integer(7)]),
            ]),
        ])
        let redacted = Redaction.redact(value)
        XCTAssertEqual(redacted["path"]?.stringValue, "~/Movies/p.aks")
        XCTAssertEqual(redacted["count"]?.integerValue, 3)
        XCTAssertEqual(redacted["ratio"]?.doubleValue, 1.5)
        XCTAssertEqual(redacted["ok"], .bool(true))
        XCTAssertEqual(redacted["missing"], .null)
        XCTAssertEqual(redacted["nested"]?["url"]?.stringValue, "https://x.test/a?key=…")
        guard case .array(let list)? = redacted["nested"]?["list"] else {
            return XCTFail("nested list lost its shape")
        }
        XCTAssertEqual(list, [.string("~/x"), .integer(7)])
    }

    private struct SampleReport: Codable, Equatable {
        var projectPath: String
        var recentPaths: [String]
        var byName: [String: String]
        var count: Int
    }

    func testTypedReportRoundTripsThroughRedaction() throws {
        let report = SampleReport(
            projectPath: "/Users/alice/Movies/demo.aks",
            recentPaths: ["/Users/alice/a.aks", "/tmp/b.aks"],
            byName: ["upload": "https://api.test/u?sig=deadbeef"],
            count: 2)
        let redacted = try Redaction.redact(report)
        XCTAssertEqual(
            redacted,
            SampleReport(
                projectPath: "~/Movies/demo.aks",
                recentPaths: ["~/a.aks", "/tmp/b.aks"],
                byName: ["upload": "https://api.test/u?sig=…"],
                count: 2))
        // The redacted report is still valid JSON and decodes back to the
        // same value — redaction never breaks the document structure.
        let data = try JSONEncoder().encode(redacted)
        XCTAssertNoThrow(try JSONSerialization.jsonObject(with: data))
        XCTAssertEqual(try JSONDecoder().decode(SampleReport.self, from: data), redacted)
    }

    func testEnvironmentReportSurvivesRedaction() throws {
        let report = EnvironmentReport.generate()
        let redacted = try Redaction.redact(report)
        XCTAssertEqual(redacted.toolVersion, report.toolVersion)
        XCTAssertEqual(redacted.physicalMemoryBytes, report.physicalMemoryBytes)
    }

    // MARK: - JSONL logs

    func testCorruptLogEntryIsSkippedNotFatal() throws {
        let log = """
            {"event":"open","path":"/Users/alice/p.aks"}
            {torn garbage that never finished writ
            {"event":"upload","url":"https://api.test/u?token=abc"}
            """
        let redacted = Redaction.redactJSONLines(log)
        let lines = redacted.split(separator: "\n")
        XCTAssertEqual(lines.count, 2, redacted)
        XCTAssertTrue(lines[0].contains("~/p.aks"), redacted)
        XCTAssertFalse(redacted.contains("nipun"), redacted)
        XCTAssertTrue(lines[1].contains("token=…"), redacted)
        XCTAssertFalse(redacted.contains("abc"), redacted)
        // Every surviving line is itself valid JSON.
        for line in lines {
            XCTAssertNoThrow(try JSONValue(data: Data(line.utf8)), String(line))
        }
    }

    func testEntirelyCorruptLogRedactsToEmpty() {
        XCTAssertEqual(Redaction.redactJSONLines("not json\nat all"), "")
    }
}
