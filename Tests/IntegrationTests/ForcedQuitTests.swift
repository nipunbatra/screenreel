import XCTest

@testable import CaptureCore
@testable import ProjectModel

/// SIGKILLs a real `screenreel record --synthetic` child process at randomized
/// moments, then recovers and validates — the automated core of the forced
/// termination matrix (ACCEPTANCE §2). The manual matrix for real capture is
/// documented in docs/MANUAL_TESTS.md.
final class ForcedQuitTests: XCTestCase {
    private var directory: URL!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("screenreel-kill-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    /// The build products directory containing the `screenreel` executable.
    private static var productsDirectory: URL {
        for bundle in Bundle.allBundles where bundle.bundlePath.hasSuffix(".xctest") {
            return bundle.bundleURL.deletingLastPathComponent()
        }
        fatalError("cannot locate build products directory")
    }

    func testKillDuringRecordingIsAlwaysRecoverable() async throws {
        let iterations = Int(ProcessInfo.processInfo.environment["SCREENREEL_KILL_ITERATIONS"] ?? "3") ?? 3
        let binary = Self.productsDirectory.appendingPathComponent("screenreel")
        guard FileManager.default.fileExists(atPath: binary.path) else {
            throw XCTSkip("screenreel executable not built next to the test bundle")
        }

        var generator = SystemRandomNumberGenerator()
        for iteration in 0..<iterations {
            let projectURL = directory.appendingPathComponent("kill-\(iteration).screenreel")
            let process = Process()
            process.executableURL = binary
            process.arguments = [
                "record", "--synthetic",
                "--duration", "60",
                "--pace", "1",
                "--width", "480", "--height", "270",
                "--output", projectURL.path,
            ]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()

            // Kill between 3 and 8 seconds in — enough for tracks, segments,
            // event chunks, and manifest replacements to be in flight.
            let delay = Double.random(in: 3...8, using: &generator)
            try await Task.sleep(for: .seconds(delay))
            kill(process.processIdentifier, SIGKILL)
            process.waitUntilExit()

            // The package exists and validation flags the incomplete session
            // without claiming corruption of committed data.
            let validation = await Validator(options: .init(verifyChecksums: true))
                .validate(projectAt: projectURL)
            XCTAssertTrue(
                validation.incompleteSessionDetected,
                "iteration \(iteration) (killed at \(delay)s): expected incomplete session")
            let unexpectedErrors = validation.issues.filter {
                $0.severity == .error
            }
            XCTAssertTrue(
                unexpectedErrors.isEmpty,
                "iteration \(iteration): committed data must verify, got \(unexpectedErrors)")

            // Recover a copy; it must be healthy and contain all committed
            // media; the original is untouched.
            let journalBefore = try Data(
                contentsOf: ProjectLayout(root: projectURL).journalURL)
            let recoveredURL = directory.appendingPathComponent("recovered-\(iteration).screenreel")
            let report = try await Recovery.recover(
                projectAt: projectURL,
                options: RecoveryOptions(
                    mediaInspector: AVMediaInspector(),
                    destination: recoveredURL))
            XCTAssertTrue(report.rejectedAssets.isEmpty, "iteration \(iteration): \(report.rejectedAssets)")
            XCTAssertEqual(
                try Data(contentsOf: ProjectLayout(root: projectURL).journalURL),
                journalBefore,
                "iteration \(iteration): recovery modified the original journal")

            let recoveredValidation = await Validator(options: .init(
                verifyChecksums: true, mediaInspector: AVMediaInspector()))
                .validate(projectAt: recoveredURL)
            XCTAssertTrue(
                recoveredValidation.isHealthy,
                "iteration \(iteration): \(recoveredValidation.issues)")

            // Recovered coverage never exceeds what was recorded, and once
            // the kill lands safely past the first 4 s segment boundary,
            // something must have been recovered. (A kill before the first
            // boundary legitimately recovers nothing — only the open
            // .partial tails existed.)
            let coverage = recoveredValidation.tracks
                .filter { $0.type.isMedia }.map(\.coverageEndNs).max() ?? 0
            if delay > 5.5 {
                XCTAssertGreaterThan(coverage, 0, "iteration \(iteration): nothing recovered")
            }
            XCTAssertLessThanOrEqual(
                coverage, Int64((delay + 1.0) * 1_000_000_000),
                "iteration \(iteration): recovered more than was recorded?")
        }
    }
}

extension ForcedQuitTests {
    /// Strengthener: aim the SIGKILL at the segment-roll window
    /// (~the 4 s boundary) — the moment a finalize chain, a fresh writer,
    /// and journal commits are all in flight at once.
    func testKillTimedAtSegmentRollIsRecoverable() async throws {
        let binary = Self.productsDirectory.appendingPathComponent("screenreel")
        guard FileManager.default.fileExists(atPath: binary.path) else {
            throw XCTSkip("screenreel executable not built next to the test bundle")
        }
        let projectURL = directory.appendingPathComponent("kill-at-roll.screenreel")
        let process = Process()
        process.executableURL = binary
        process.arguments = [
            "record", "--synthetic",
            "--duration", "60", "--pace", "1",
            "--width", "480", "--height", "270",
            "--output", projectURL.path,
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()

        // Segment duration defaults to 4 s; land inside the roll window
        // just after the first boundary.
        try await Task.sleep(for: .seconds(4.05))
        kill(process.processIdentifier, SIGKILL)
        process.waitUntilExit()

        let recover = Process()
        recover.executableURL = binary
        recover.arguments = ["recover", projectURL.path]
        let pipe = Pipe()
        recover.standardOutput = pipe
        recover.standardError = pipe
        try recover.run()
        recover.waitUntilExit()
        XCTAssertEqual(recover.terminationStatus, 0, "recover must succeed")

        // The recovered copy validates.
        let recoveredURL = try XCTUnwrap(
            FileManager.default
                .contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                .first { $0.lastPathComponent.contains("kill-at-roll")
                    && $0.lastPathComponent.contains("recovered") }
                ?? projectURL)
        let validate = Process()
        validate.executableURL = binary
        validate.arguments = ["validate", recoveredURL.path]
        validate.standardOutput = FileHandle.nullDevice
        validate.standardError = FileHandle.nullDevice
        try validate.run()
        validate.waitUntilExit()
        XCTAssertEqual(validate.terminationStatus, 0)
    }
}
