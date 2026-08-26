import AVFoundation
import XCTest

@testable import ExportEngine
@testable import PreviewEngine
@testable import ProjectModel
@testable import TimelineCore

final class AspectAndThumbnailTests: XCTestCase {
    private var directory: URL!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("aks-aspect-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    func testVerticalStyledExportHonorsCanvasAspect() async throws {
        let projectURL = try await SyntheticProjectFactory.make(
            in: directory, durationNs: 5_000_000_000, withEvents: false)
        let composition = try ProjectComposition(projectURL: projectURL)
        try composition.updateEdits { $0.style.canvasAspect = 9.0 / 16.0 }

        let outputURL = directory.appendingPathComponent("vertical.mp4")
        let result = try await StyledExporter.export(
            projectAt: projectURL, to: outputURL,
            options: .init(fps: 30, outputHeight: 320))
        XCTAssertGreaterThan(result.videoFrames, 100)

        let asset = AVURLAsset(url: outputURL)
        let track = try await asset.loadTracks(withMediaType: .video)[0]
        let size = try await track.load(.naturalSize)
        XCTAssertEqual(size.height, 320)
        XCTAssertEqual(size.width, 180)  // 9:16 at even dimensions
        let duration = try await asset.load(.duration)
        XCTAssertEqual(duration.seconds, 5.0, accuracy: 0.25)
    }

    func testThumbnailGeneratesCachesAndInvalidates() async throws {
        let projectURL = try await SyntheticProjectFactory.make(
            in: directory, durationNs: 5_000_000_000, withEvents: false)

        let first = await ProjectThumbnailer.thumbnail(for: projectURL, height: 120)
        XCTAssertNotNil(first)
        let cache = ProjectThumbnailer.cacheURL(for: projectURL, height: 120)
        XCTAssertTrue(FileManager.default.fileExists(atPath: cache.path))
        XCTAssertEqual(first?.height, 120)

        // Second call loads the cached PNG (same content, no re-render).
        let stamp = try FileManager.default
            .attributesOfItem(atPath: cache.path)[.modificationDate] as? Date
        let second = await ProjectThumbnailer.thumbnail(for: projectURL, height: 120)
        XCTAssertNotNil(second)
        let stampAfter = try FileManager.default
            .attributesOfItem(atPath: cache.path)[.modificationDate] as? Date
        XCTAssertEqual(stamp, stampAfter)

        // Invalidation removes the derived cache; raw stays untouched.
        ProjectThumbnailer.invalidate(for: projectURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: cache.path))
        let report = await Validator(options: .init(verifyChecksums: true))
            .validate(projectAt: projectURL)
        XCTAssertTrue(report.isHealthy, "\(report.issues)")
    }

    func testThumbnailOnDamagedProjectReturnsNilWithoutCrash() async throws {
        let projectURL = try await SyntheticProjectFactory.make(
            in: directory, durationNs: 5_000_000_000, withEvents: false)
        // Destroy the journal: composition must refuse, thumbnailer must
        // degrade to nil.
        let journal = ProjectLayout(root: projectURL).journalURL
        try Data("garbage".utf8).write(to: journal)
        let thumbnail = await ProjectThumbnailer.thumbnail(for: projectURL, height: 120)
        XCTAssertNil(thumbnail)

        // A directory that is not a project at all.
        let notAProject = directory.appendingPathComponent("not-a-project.aks")
        try FileManager.default.createDirectory(at: notAProject, withIntermediateDirectories: true)
        let none = await ProjectThumbnailer.thumbnail(for: notAProject, height: 120)
        XCTAssertNil(none)
    }
}
