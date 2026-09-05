import Foundation
import ProjectModel
import XCTest

@testable import ExportEngine
@testable import PreviewEngine

/// Export failure contract: a project with a missing MIDDLE
/// segment must fail with an error naming the missing asset — never crash,
/// never render a silent black span.
final class ExportErrorContractTests: XCTestCase {

    func testMissingMiddleSegmentFailsNamingTheAsset() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("screenreel-missmid-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        let projectURL = try await SyntheticProjectFactory.make(
            in: directory, durationNs: 9_000_000_000)

        // Delete the middle screen segment file (raw sabotage, as a failed
        // disk would leave it).
        let layout = ProjectLayout(root: projectURL)
        let screenFiles = try FileManager.default
            .contentsOfDirectory(at: layout.screenDirectory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "mov" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        XCTAssertGreaterThanOrEqual(screenFiles.count, 3, "need a middle segment")
        let victim = screenFiles[1]
        try FileManager.default.removeItem(at: victim)

        do {
            _ = try await StyledExporter.export(
                projectAt: projectURL,
                to: directory.appendingPathComponent("out.mp4"),
                options: .init(fps: 30, outputHeight: 180))
            XCTFail("export must fail when a segment file is missing")
        } catch {
            let message = "\(error)"
            XCTAssertTrue(
                message.contains(victim.lastPathComponent)
                    || message.contains("raw/screen"),
                "error must name the missing asset, got: \(message)")
        }
    }
}
