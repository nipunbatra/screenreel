import XCTest

@testable import PreviewEngine
@testable import ProjectModel

/// End-to-end runs of the actual `screenreel` binary: exit codes, JSON output, and
/// the record → validate → export → re-validate loop a user lives in.
final class CLITests: XCTestCase {
    private var directory: URL!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("screenreel-cli-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    private static var binary: URL {
        for bundle in Bundle.allBundles where bundle.bundlePath.hasSuffix(".xctest") {
            return bundle.bundleURL.deletingLastPathComponent().appendingPathComponent("screenreel")
        }
        fatalError("cannot locate build products directory")
    }

    @discardableResult
    private func run(_ arguments: [String]) throws -> (status: Int32, stdout: String) {
        let process = Process()
        process.executableURL = Self.binary
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }

    func testRecordValidateExportLoop() throws {
        guard FileManager.default.fileExists(atPath: Self.binary.path) else {
            throw XCTSkip("screenreel binary not built next to the test bundle")
        }
        let project = directory.appendingPathComponent("cli.screenreel").path

        // Record.
        let record = try run([
            "record", "--synthetic", "--duration", "6", "--pace", "4",
            "--width", "320", "--height", "180", "--output", project,
        ])
        XCTAssertEqual(record.status, 0, record.stdout)
        XCTAssertTrue(record.stdout.contains("Validation: healthy"), record.stdout)

        // Validate with JSON output.
        let validate = try run(["validate", project, "--json"])
        XCTAssertEqual(validate.status, 0)
        let report = try JSONDecoder().decode(
            ValidationReport.self, from: Data(validate.stdout.utf8))
        XCTAssertTrue(report.isHealthy)
        XCTAssertTrue(report.journalFinalized)

        // Inspect JSON parses and matches the project.
        let inspect = try run(["inspect", project, "--json"])
        XCTAssertEqual(inspect.status, 0)
        XCTAssertTrue(inspect.stdout.contains("\"schemaVersion\" : 1"))

        // Export (raw), verify exit and file; a second export without --force
        // must refuse with a nonzero exit and leave the file alone.
        let mp4 = directory.appendingPathComponent("cli.mp4").path
        let export = try run(["export", project, mp4])
        XCTAssertEqual(export.status, 0, export.stdout)
        XCTAssertTrue(FileManager.default.fileExists(atPath: mp4))
        let sizeBefore = try FileManager.default.attributesOfItem(atPath: mp4)[.size] as? Int64
        let refused = try run(["export", project, mp4])
        XCTAssertNotEqual(refused.status, 0)
        let sizeAfter = try FileManager.default.attributesOfItem(atPath: mp4)[.size] as? Int64
        XCTAssertEqual(sizeBefore, sizeAfter)

        // Styled export works through the CLI too.
        let styledOut = directory.appendingPathComponent("cli-styled.mp4").path
        let styled = try run(["export", project, styledOut, "--styled", "--height", "180"])
        XCTAssertEqual(styled.status, 0, styled.stdout)
        XCTAssertTrue(FileManager.default.fileExists(atPath: styledOut))

        // The whole loop never touched the raw recording.
        let final = try run(["validate", project])
        XCTAssertEqual(final.status, 0)
    }

    func testValidateFailsOnCorruptedProject() throws {
        guard FileManager.default.fileExists(atPath: Self.binary.path) else {
            throw XCTSkip("screenreel binary not built next to the test bundle")
        }
        let project = directory.appendingPathComponent("corrupt.screenreel").path
        let record = try run([
            "record", "--synthetic", "--duration", "6", "--pace", "4",
            "--width", "320", "--height", "180", "--output", project,
        ])
        XCTAssertEqual(record.status, 0)

        // Flip a byte inside the first mic segment.
        let mic = URL(fileURLWithPath: project)
            .appendingPathComponent("raw/microphone/mic-000001.caf")
        var data = try Data(contentsOf: mic)
        data[data.count / 2] ^= 0xFF
        try data.write(to: mic)

        let validate = try run(["validate", project])
        XCTAssertNotEqual(validate.status, 0)
        XCTAssertTrue(validate.stdout.contains("checksumMismatch"), validate.stdout)

        // Export refuses nothing here (journal intact) but recovery rejects
        // and quarantines the corrupt segment; recovered copy validates.
        let recovered = directory.appendingPathComponent("recovered.screenreel").path
        let recover = try run(["recover", project, "--output", recovered])
        XCTAssertEqual(recover.status, 0, recover.stdout)
        let revalidate = try run(["validate", recovered])
        XCTAssertEqual(revalidate.status, 0, revalidate.stdout)
    }
}

extension CLITests {
    /// End-to-end keystroke pipeline: `--keystrokes` must register the
    /// keyboard track, persist keyDown chunks, survive validation, and
    /// surface as key presses in the composition. (The original wiring
    /// enabled the tap but never registered the track, so every event was
    /// silently dropped by the store's uncaptured-kind guard.)
    func testSyntheticKeystrokesFlowIntoTheComposition() throws {
        guard FileManager.default.fileExists(atPath: Self.binary.path) else {
            throw XCTSkip("screenreel binary not built next to the test bundle")
        }
        let project = directory.appendingPathComponent("keys.screenreel").path

        let record = try run([
            "record", "--synthetic", "--keystrokes", "--duration", "6",
            "--pace", "4", "--width", "320", "--height", "180",
            "--output", project,
        ])
        XCTAssertEqual(record.status, 0, record.stdout)

        // A keyboard chunk exists on disk…
        let eventFiles = (try? FileManager.default.contentsOfDirectory(
            atPath: project + "/events")) ?? []
        XCTAssertTrue(
            eventFiles.contains { $0.hasPrefix("keyboard-") },
            "no keyboard chunk written: \(eventFiles)")

        // …the project still validates…
        let validate = try run(["validate", project])
        XCTAssertEqual(validate.status, 0, validate.stdout)

        // …and the composition sees the presses (6 s / 2 s click period =
        // 2 shortcut presses, ⌘C each).
        let composition = try ProjectComposition(
            projectURL: URL(fileURLWithPath: project))
        XCTAssertTrue(composition.hasKeystrokes)
        XCTAssertGreaterThanOrEqual(
            composition.motionTimeline.keyPresses.count, 2)
        XCTAssertEqual(composition.motionTimeline.keyPresses[0].keyCode, 8)
        XCTAssertEqual(
            composition.motionTimeline.keyPresses[0].modifiers, [.command])

        // Control: WITHOUT the flag, no keyboard track appears.
        let plain = directory.appendingPathComponent("plain.screenreel").path
        _ = try run([
            "record", "--synthetic", "--duration", "3", "--pace", "4",
            "--width", "320", "--height", "180", "--output", plain,
        ])
        let plainFiles = (try? FileManager.default.contentsOfDirectory(
            atPath: plain + "/events")) ?? []
        XCTAssertFalse(plainFiles.contains { $0.hasPrefix("keyboard-") })
    }
}
