import Foundation
import ImageIO
import ProjectModel
import TimelineCore
import XCTest

@testable import ExportEngine
@testable import PreviewEngine

/// Animated-GIF export: same composition graph as MP4, atomic appearance,
/// honest frame counts, and clean cancellation.
final class GIFExportTests: XCTestCase {

    private var directory: URL!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("screenreel-gif-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    private func frameInfo(_ url: URL) throws -> (count: Int, width: Int, height: Int, loop: Int?) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw NSError(domain: "gif", code: 1)
        }
        let count = CGImageSourceGetCount(source)
        var width = 0
        var height = 0
        if let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
            as? [CFString: Any]
        {
            width = props[kCGImagePropertyPixelWidth] as? Int ?? 0
            height = props[kCGImagePropertyPixelHeight] as? Int ?? 0
        }
        let container = CGImageSourceCopyProperties(source, nil) as? [CFString: Any]
        let gif = container?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
        let loop = gif?[kCGImagePropertyGIFLoopCount] as? Int
        return (count, width, height, loop)
    }

    func testGIFMatchesDurationSizeAndLoops() async throws {
        let projectURL = try await SyntheticProjectFactory.make(
            in: directory, durationNs: 3_000_000_000)
        let outputURL = directory.appendingPathComponent("demo.gif")

        let summary = try await GIFExporter.export(
            projectURL: projectURL, to: outputURL,
            options: .init(fps: 10, maxHeight: 120, overwrite: true))

        // 3 s at 10 fps.
        XCTAssertEqual(summary.frames, 30)
        let info = try frameInfo(outputURL)
        XCTAssertEqual(info.count, 30)
        XCTAssertEqual(info.height, summary.height)
        XCTAssertEqual(info.width, summary.width)
        XCTAssertLessThanOrEqual(info.height, 120)
        XCTAssertEqual(info.loop, 0, "GIF must loop forever")
        XCTAssertGreaterThan(summary.byteSize, 0)
        // No temp litter next to the output.
        let siblings = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertFalse(
            siblings.contains { $0.hasPrefix(".gif-export-") },
            "temp file must not survive: \(siblings)")
    }

    func testGIFRespectsCutsAndTrim() async throws {
        let projectURL = try await SyntheticProjectFactory.make(
            in: directory, durationNs: 9_000_000_000)
        let composition = try ProjectComposition(projectURL: projectURL)
        try composition.updateEdits { edits in
            // Cut the middle third, then trim the last output second:
            // output = 6 s cut → [0, 5) after trim.
            edits.clips = [
                Clip(sourceStartNs: 0, sourceEndNs: 3_000_000_000),
                Clip(sourceStartNs: 6_000_000_000, sourceEndNs: 9_000_000_000),
            ]
            edits.trimEndNs = 5_000_000_000
        }

        let outputURL = directory.appendingPathComponent("cut.gif")
        let summary = try await GIFExporter.export(
            projectURL: projectURL, to: outputURL,
            options: .init(fps: 10, maxHeight: 90, overwrite: true))
        XCTAssertEqual(summary.frames, 50, "5 s at 10 fps")
        XCTAssertEqual(try frameInfo(outputURL).count, 50)
    }

    func testRefusesToOverwriteWithoutFlag() async throws {
        let projectURL = try await SyntheticProjectFactory.make(
            in: directory, durationNs: 1_000_000_000)
        let outputURL = directory.appendingPathComponent("exists.gif")
        try Data("sentinel".utf8).write(to: outputURL)

        do {
            _ = try await GIFExporter.export(
                projectURL: projectURL, to: outputURL,
                options: .init(fps: 10, maxHeight: 90, overwrite: false))
            XCTFail("must refuse to overwrite")
        } catch {
            // Refused: the sentinel bytes are untouched.
            XCTAssertEqual(
                try Data(contentsOf: outputURL), Data("sentinel".utf8))
        }
    }

    func testCancelledExportLeavesNothingBehind() async throws {
        let projectURL = try await SyntheticProjectFactory.make(
            in: directory, durationNs: 8_000_000_000)
        let outputURL = directory.appendingPathComponent("cancelled.gif")

        let task = Task {
            try await GIFExporter.export(
                projectURL: projectURL, to: outputURL,
                options: .init(fps: 30, maxHeight: 240, overwrite: true))
        }
        try await Task.sleep(nanoseconds: 250_000_000)
        task.cancel()
        do {
            _ = try await task.value
            // Finished before the cancel landed — that's fine too.
        } catch {
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: outputURL.path),
                "cancelled export must not leave a partial GIF")
        }
        let siblings = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertFalse(
            siblings.contains { $0.hasPrefix(".gif-export-") },
            "cancelled export must clean its temp file: \(siblings)")
    }
}

extension GIFExportTests {
    /// ImageIO holds every appended frame until finalize; a long range must
    /// refuse up front with a way out instead of exhausting memory.
    func testOverBudgetRangeRefusesWithActionableError() async throws {
        // A 1080p source: the GIF height cap follows the source, so the
        // budget math sees real numbers (450 frames × 1920×1080 ≈ 0.9e9 px).
        let projectURL = try await SyntheticProjectFactory.make(
            in: directory, durationNs: 9_000_000_000, width: 1920, height: 1080)
        let outputURL = directory.appendingPathComponent("huge.gif")
        do {
            _ = try await GIFExporter.export(
                projectURL: projectURL, to: outputURL,
                options: .init(fps: 50, maxHeight: 2160, overwrite: true))
            XCTFail("must refuse over-budget GIFs")
        } catch {
            let message = "\(error)"
            XCTAssertTrue(
                message.contains("Trim or cut"),
                "error must tell the user the way out: \(message)")
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: outputURL.path))
        }
    }
}
