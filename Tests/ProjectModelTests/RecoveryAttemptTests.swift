import XCTest

@testable import ProjectModel

/// Terminal recovery status: a FAILED recovery is
/// terminal — a second run refuses with "already attempted, see diagnostics"
/// instead of retrying in a loop — while a successful recovery clears the
/// attempt marker and leaves no residue.
final class RecoveryAttemptTests: XCTestCase {
    private var directory: URL!

    override func setUp() {
        super.setUp()
        AtomicFile.fullFsync = false
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("screenreel-attempt-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        AtomicFile.fullFsync = true
        super.tearDown()
    }

    private var projectURL: URL { directory.appendingPathComponent("p.screenreel") }
    private var markerURL: URL {
        RecoveryAttemptMarker.url(in: ProjectLayout(root: projectURL))
    }

    /// A destination nested under a regular FILE passes the exists pre-check
    /// but fails when recovery creates the package — a deterministic
    /// in-flight failure.
    private func blockedDestination() throws -> URL {
        let blocker = directory.appendingPathComponent("blocker")
        try Data("not a directory".utf8).write(to: blocker)
        return blocker.appendingPathComponent("recovered.screenreel")
    }

    func testFailedRecoveryIsTerminalAndSecondRunRefuses() async throws {
        try await TestProject.build(at: projectURL, finalize: false)

        do {
            _ = try await Recovery.recover(
                projectAt: projectURL,
                options: RecoveryOptions(destination: try blockedDestination()))
            XCTFail("expected the blocked destination to fail recovery")
        } catch is RecoveryError {
            XCTFail("the first attempt must fail with the underlying error, not the terminal gate")
        } catch {
            // expected: the package-creation failure itself
        }

        // The marker survives in the fixture with the failure recorded.
        let marker = try XCTUnwrap(
            RecoveryAttemptMarker.read(from: ProjectLayout(root: projectURL)))
        XCTAssertEqual(marker.outcome, .failed)
        XCTAssertNotNil(marker.finishedAt)
        XCTAssertNotNil(marker.error)
        XCTAssertEqual(marker.toolVersion, ProjectSchema.toolVersion)

        // A second run — even with a perfectly good destination — refuses.
        do {
            _ = try await Recovery.recover(
                projectAt: projectURL,
                options: RecoveryOptions(
                    destination: directory.appendingPathComponent("good.screenreel")))
            XCTFail("expected alreadyAttempted")
        } catch let error as RecoveryError {
            guard case .alreadyAttempted = error else {
                return XCTFail("expected alreadyAttempted, got \(error)")
            }
            XCTAssertTrue(
                "\(error)".contains("already attempted, see diagnostics"), "\(error)")
        }
        // Nothing was created by the refused run, and the marker persists.
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("good.screenreel").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: markerURL.path))

        // Validation is read-only: the marker survives it too.
        _ = await Validator().validate(projectAt: projectURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: markerURL.path))
    }

    func testSuccessfulRecoveryClearsMarkerAndStaysRepeatable() async throws {
        try await TestProject.build(at: projectURL, finalize: false)

        let firstURL = directory.appendingPathComponent("recovered-1.screenreel")
        _ = try await Recovery.recover(
            projectAt: projectURL, options: RecoveryOptions(destination: firstURL))
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: markerURL.path),
            "a successful recovery must clear the attempt marker")

        // Success is not terminal: a repeat run still works.
        let secondURL = directory.appendingPathComponent("recovered-2.screenreel")
        _ = try await Recovery.recover(
            projectAt: projectURL, options: RecoveryOptions(destination: secondURL))
        XCTAssertFalse(FileManager.default.fileExists(atPath: markerURL.path))

        // The recovered copies carry no marker either.
        for recovered in [firstURL, secondURL] {
            XCTAssertFalse(FileManager.default.fileExists(
                atPath: RecoveryAttemptMarker.url(in: ProjectLayout(root: recovered)).path))
        }
    }

    /// Preflight refusals are caller errors, not failed attempts: neither an
    /// occupied destination nor a live writer may mark the project terminal.
    func testPreflightRefusalsLeaveNoMarker() async throws {
        let built = try await TestProject.build(at: projectURL, finalize: false)

        // Occupied destination.
        let occupied = directory.appendingPathComponent("occupied.screenreel")
        try FileManager.default.createDirectory(at: occupied, withIntermediateDirectories: true)
        do {
            _ = try await Recovery.recover(
                projectAt: projectURL, options: RecoveryOptions(destination: occupied))
            XCTFail("expected EEXIST refusal")
        } catch {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: markerURL.path))

        // Live writer.
        let lock = SessionLock(sessionID: UUID())  // this test process, alive
        try lock.write(to: built.layout.sessionLockURL)
        do {
            _ = try await Recovery.recover(projectAt: projectURL)
            XCTFail("expected sessionActive refusal")
        } catch {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: markerURL.path))

        // After the refusals the project is still recoverable normally.
        var stale = SessionLock(sessionID: UUID())
        stale.pid = 99999
        stale.processStartMarker = "99999:1.1"
        try stale.write(to: built.layout.sessionLockURL)
        let recovered = directory.appendingPathComponent("after-preflight.screenreel")
        _ = try await Recovery.recover(
            projectAt: projectURL, options: RecoveryOptions(destination: recovered))
        XCTAssertFalse(FileManager.default.fileExists(atPath: markerURL.path))
    }

    func testUnreadableMarkerStillGatesRetry() async throws {
        try await TestProject.build(at: projectURL, finalize: false)
        try Data("torn marker garbage".utf8).write(to: markerURL)

        do {
            _ = try await Recovery.recover(
                projectAt: projectURL,
                options: RecoveryOptions(
                    destination: directory.appendingPathComponent("out.screenreel")))
            XCTFail("expected alreadyAttempted for a corrupt marker")
        } catch let error as RecoveryError {
            guard case .alreadyAttempted = error else {
                return XCTFail("expected alreadyAttempted, got \(error)")
            }
        }
        // The corrupt marker's bytes were not replaced by the refusal.
        XCTAssertEqual(try Data(contentsOf: markerURL), Data("torn marker garbage".utf8))
    }
}
