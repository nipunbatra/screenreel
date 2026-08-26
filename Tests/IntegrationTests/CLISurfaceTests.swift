import XCTest

@testable import ProjectModel

/// Golden CLI surface matrix: the CLI is the recovery front
/// door, so its contract is pinned — every subcommand's `--help` works, JSON
/// outputs parse, corrupt input produces a structured error naming the path
/// with a pinned exit code and no stack trace, and export failures name the
/// exact missing asset.
final class CLISurfaceTests: XCTestCase {
    private var directory: URL!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("aks-clisurface-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    // MARK: - Process plumbing

    private static var binary: URL {
        for bundle in Bundle.allBundles where bundle.bundlePath.hasSuffix(".xctest") {
            return bundle.bundleURL.deletingLastPathComponent().appendingPathComponent("aks")
        }
        fatalError("cannot locate build products directory")
    }

    private func requireBinary() throws {
        guard FileManager.default.fileExists(atPath: Self.binary.path) else {
            throw XCTSkip("aks binary not built next to the test bundle")
        }
    }

    /// Drains one pipe off-thread so stdout and stderr can both be captured
    /// without a full-buffer deadlock.
    private final class OutputAccumulator: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        private let finished = DispatchSemaphore(value: 0)
        let pipe = Pipe()

        init() {
            pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let chunk = handle.availableData
                guard let self else { return }
                if chunk.isEmpty {
                    handle.readabilityHandler = nil
                    self.finished.signal()
                } else {
                    self.lock.lock()
                    self.data.append(chunk)
                    self.lock.unlock()
                }
            }
        }

        func text() -> String {
            finished.wait()
            lock.lock()
            defer { lock.unlock() }
            return String(data: data, encoding: .utf8) ?? ""
        }
    }

    @discardableResult
    private func run(_ arguments: [String]) throws -> (status: Int32, stdout: String, stderr: String) {
        let process = Process()
        process.executableURL = Self.binary
        process.arguments = arguments
        let out = OutputAccumulator()
        let err = OutputAccumulator()
        process.standardOutput = out.pipe
        process.standardError = err.pipe
        try process.run()
        let stdout = out.text()
        let stderr = err.text()
        process.waitUntilExit()
        return (process.terminationStatus, stdout, stderr)
    }

    private func recordFixture(name: String, seconds: Int) throws -> String {
        let project = directory.appendingPathComponent("\(name).aks").path
        let record = try run([
            "record", "--synthetic", "--duration", "\(seconds)", "--pace", "4",
            "--width", "320", "--height", "180", "--output", project,
        ])
        XCTAssertEqual(record.status, 0, record.stdout + record.stderr)
        XCTAssertTrue(record.stdout.contains("Validation: healthy"), record.stdout)
        return project
    }

    private func assertNoStackTrace(_ stderr: String, _ context: String) {
        XCTAssertFalse(stderr.contains("Fatal error"), "\(context): crashed — \(stderr)")
        XCTAssertFalse(stderr.contains("stack trace"), "\(context): stack trace — \(stderr)")
        XCTAssertFalse(stderr.contains("Trace/BPT"), "\(context): trapped — \(stderr)")
    }

    // MARK: - Help matrix

    /// Every subcommand enumerated from `aks --help` answers `--help` with
    /// exit 0 and a usage block; the enumeration itself must contain the
    /// full known command surface so removals are caught.
    func testEverySubcommandHelpSucceeds() throws {
        try requireBinary()
        let root = try run(["--help"])
        XCTAssertEqual(root.status, 0, root.stderr)
        XCTAssertTrue(root.stdout.contains("USAGE:"), root.stdout)

        var subcommands: [String] = []
        var inSection = false
        for line in root.stdout.components(separatedBy: "\n") {
            if line.hasPrefix("SUBCOMMANDS:") {
                inSection = true
                continue
            }
            guard inSection else { continue }
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("See ") { break }
            // Subcommand rows are exactly two-space indented
            // ("  record    Record a segmented …"); wrapped abstract text
            // continues at a deeper indent and must not match.
            guard line.hasPrefix("  "), !line.hasPrefix("   "),
                let first = line.split(separator: " ").first
            else { continue }
            subcommands.append(String(first))
        }

        let expected: Set<String> = [
            "record", "export", "validate", "recover", "extract", "inspect",
            "selftest", "env", "diagnose", "captions",
        ]
        XCTAssertEqual(
            Set(subcommands), expected,
            "aks --help no longer lists the pinned command surface: \(subcommands)")

        for subcommand in subcommands {
            let help = try run([subcommand, "--help"])
            XCTAssertEqual(help.status, 0, "\(subcommand) --help failed: \(help.stderr)")
            XCTAssertTrue(
                help.stdout.contains("USAGE:"),
                "\(subcommand) --help printed no usage: \(help.stdout)")
            assertNoStackTrace(help.stderr, "\(subcommand) --help")
        }
    }

    // MARK: - Corrupt input

    /// A package whose manifest is garbage: validate and inspect must fail
    /// with the pinned exit code, name the offending path, and never dump a
    /// Swift crash to stderr.
    func testCorruptProjectProducesStructuredErrors() throws {
        try requireBinary()
        let corrupt = directory.appendingPathComponent("mangled.aks")
        try FileManager.default.createDirectory(at: corrupt, withIntermediateDirectories: true)
        try Data("{ not json ]]".utf8).write(
            to: corrupt.appendingPathComponent("manifest.json"))

        let validate = try run(["validate", corrupt.path])
        XCTAssertEqual(validate.status, 1, "pinned failure exit code")
        XCTAssertTrue(
            (validate.stdout + validate.stderr).contains("mangled.aks"),
            "validate error must name the path: \(validate.stdout)\n\(validate.stderr)")
        assertNoStackTrace(validate.stderr, "validate corrupt")

        let inspect = try run(["inspect", corrupt.path])
        XCTAssertEqual(inspect.status, 1, "pinned failure exit code")
        XCTAssertTrue(
            (inspect.stdout + inspect.stderr).contains("mangled.aks"),
            "inspect error must name the path: \(inspect.stdout)\n\(inspect.stderr)")
        assertNoStackTrace(inspect.stderr, "inspect corrupt")

        // A path that is not a project at all gets the same contract.
        let missing = directory.appendingPathComponent("nothing.aks").path
        let ghost = try run(["inspect", missing])
        XCTAssertEqual(ghost.status, 1)
        XCTAssertTrue(
            (ghost.stdout + ghost.stderr).contains("nothing.aks"),
            ghost.stdout + ghost.stderr)
        assertNoStackTrace(ghost.stderr, "inspect missing")
    }

    // MARK: - Round trip

    /// validate → recover → validate → inspect on a good project, with every
    /// JSON output parsing.
    func testValidateRecoverInspectRoundTrip() throws {
        try requireBinary()
        let project = try recordFixture(name: "roundtrip", seconds: 6)

        let validate = try run(["validate", project, "--json"])
        XCTAssertEqual(validate.status, 0, validate.stdout + validate.stderr)
        let report = try JSONDecoder().decode(
            ValidationReport.self, from: Data(validate.stdout.utf8))
        XCTAssertTrue(report.isHealthy)
        XCTAssertTrue(report.journalFinalized)

        let inspect = try run(["inspect", project, "--json"])
        XCTAssertEqual(inspect.status, 0)
        let inspectJSON = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(inspect.stdout.utf8)) as? [String: Any],
            "inspect --json must emit a JSON object")
        XCTAssertNotNil(inspectJSON["manifest"], "\(inspectJSON.keys)")

        let recovered = directory.appendingPathComponent("roundtrip-recovered.aks").path
        let recover = try run(["recover", project, "--output", recovered, "--json"])
        XCTAssertEqual(recover.status, 0, recover.stdout + recover.stderr)
        XCTAssertNotNil(
            try JSONSerialization.jsonObject(with: Data(recover.stdout.utf8)) as? [String: Any],
            "recover --json must emit a JSON object")

        let revalidate = try run(["validate", recovered, "--json"])
        XCTAssertEqual(revalidate.status, 0, revalidate.stdout + revalidate.stderr)
        let recoveredReport = try JSONDecoder().decode(
            ValidationReport.self, from: Data(revalidate.stdout.utf8))
        XCTAssertTrue(recoveredReport.isHealthy, "\(recoveredReport.issues)")

        let reinspect = try run(["inspect", recovered])
        XCTAssertEqual(reinspect.status, 0, reinspect.stderr)
        XCTAssertTrue(reinspect.stdout.contains("Track:"), reinspect.stdout)
    }

    // MARK: - Export with a hole

    /// Deleting a *middle* screen segment must fail export up front with an
    /// error naming the missing file's relative path and a recovery action —
    /// not a crash, a wedge, or a silent black span.
    func testExportFailsNamingMissingMiddleSegment() throws {
        try requireBinary()
        // 10 s at 4 s segments → 3 committed screen segments.
        let project = try recordFixture(name: "hole", seconds: 10)

        let screenDir = URL(fileURLWithPath: project).appendingPathComponent("raw/screen")
        let segments = try FileManager.default.contentsOfDirectory(atPath: screenDir.path)
            .filter { $0.hasSuffix(".mov") }
            .sorted()
        XCTAssertGreaterThanOrEqual(segments.count, 3, "\(segments)")
        let middle = segments[1]
        try FileManager.default.removeItem(at: screenDir.appendingPathComponent(middle))

        let output = directory.appendingPathComponent("hole.mp4").path
        let export = try run(["export", project, output])
        XCTAssertEqual(export.status, 1, "pinned failure exit code")
        XCTAssertTrue(
            export.stderr.contains("raw/screen/\(middle)"),
            "export error must name the missing segment's relative path: \(export.stderr)")
        XCTAssertTrue(
            export.stderr.contains("recover"),
            "export error must point at the recovery action: \(export.stderr)")
        assertNoStackTrace(export.stderr, "export with missing middle segment")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: output),
            "failed export must not leave an output file")

        // The styled path preflights identically.
        let styled = try run(["export", project, output, "--styled"])
        XCTAssertEqual(styled.status, 1)
        XCTAssertTrue(styled.stderr.contains("raw/screen/\(middle)"), styled.stderr)
    }
}
