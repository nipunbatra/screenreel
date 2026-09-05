import XCTest

@testable import ProjectModel

final class LayoutPathTests: XCTestCase {

    /// `/private/tmp/...` is the trap: `standardizedFileURL` rewrites it to
    /// `/tmp/...` only for paths that exist, so a layout whose root was
    /// captured BEFORE the package directory existed must still produce
    /// package-relative paths for files created afterwards.
    func testRelativePathSurvivesPrivateTmpStandardization() throws {
        let root = URL(fileURLWithPath: "/private/tmp/aks-layout-\(UUID().uuidString).aks")
            .standardizedFileURL
        let layout = ProjectLayout(root: root)
        defer { try? FileManager.default.removeItem(at: root) }

        let file = layout.screenDirectory.appendingPathComponent("display-1-000001.mov")
        XCTAssertEqual(layout.relativePath(of: file), "raw/screen/display-1-000001.mov")

        // Now the directories exist and standardization flips /private/tmp
        // to /tmp for the file: the result must not change.
        try FileManager.default.createDirectory(
            at: layout.screenDirectory, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: file)
        XCTAssertEqual(layout.relativePath(of: file), "raw/screen/display-1-000001.mov")
        XCTAssertEqual(
            layout.relativePath(of: file.standardizedFileURL), "raw/screen/display-1-000001.mov")
        XCTAssertEqual(
            layout.relativePath(of: file.resolvingSymlinksInPath()),
            "raw/screen/display-1-000001.mov")

        // Files outside the package keep their absolute path.
        let outside = URL(fileURLWithPath: "/private/tmp/elsewhere.mov")
        XCTAssertEqual(layout.relativePath(of: outside), outside.path)
    }
}
