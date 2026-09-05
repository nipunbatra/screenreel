import XCTest

@testable import ProjectModel

/// The product was renamed from "aks" to Screenreel; everything it ever
/// wrote must keep opening.
final class LegacyIdentifierTests: XCTestCase {

    func testNewManifestsCarryTheCurrentIdentifiers() {
        let manifest = Manifest(
            state: .ready,
            clock: ClockAnchor(
                originContinuousTicks: 0, originAbsoluteTicks: 0,
                timebaseNumer: 1, timebaseDenom: 1, originWallTime: RFC3339.now()))
        XCTAssertEqual(manifest.format, "com.nipunbatra.screenreel.project")
        XCTAssertEqual(manifest.appVersion, "screenreel 0.2.0")
        XCTAssertEqual(ProjectSchema.packageExtension, "screenreel")
    }

    func testLegacyFormatIdentifierStillDecodes() throws {
        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/v1/fixture-v1.aks/manifest.json")
        let data = try Data(contentsOf: fixture)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("in.aks.project"))
        let manifest = try Manifest.decode(from: data, path: fixture.path)
        XCTAssertEqual(manifest.format, "in.aks.project")
        XCTAssertNoThrow(try manifest.checkReadable(at: fixture.path))
    }

    func testUnknownFormatIsRejected() {
        let json = #"{"format":"com.example.other","schemaVersion":1}"#
        XCTAssertThrowsError(try Manifest.decode(from: Data(json.utf8), path: "x"))
    }

    func testPackageExtensions() {
        XCTAssertTrue(ProjectSchema.isPackageExtension("screenreel"))
        XCTAssertTrue(ProjectSchema.isPackageExtension("aks"))
        XCTAssertFalse(ProjectSchema.isPackageExtension("mov"))
        XCTAssertFalse(ProjectSchema.isPackageExtension(""))
    }
}
