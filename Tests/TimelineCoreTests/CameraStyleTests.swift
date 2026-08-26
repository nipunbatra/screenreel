import Foundation
import XCTest

@testable import TimelineCore

/// Edit documents written before the camera field existed must keep loading
/// (CLAUDE.md: old projects remain readable), and the new field must
/// round-trip.
final class CameraStyleTests: XCTestCase {

    func testLegacyDocumentWithoutCameraDecodesToDefaults() throws {
        // A pre-camera document, exactly as older builds wrote it.
        var legacy = EditDocument(
            style: FrameStyle(padding: 0.1),
            zooms: [ZoomSegment(startNs: 0, endNs: 1_000_000_000, scale: 2)],
            trimStartNs: 5)
        legacy.schemaVersion = 1
        var json = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(legacy)) as! [String: Any]
        json.removeValue(forKey: "camera")
        let data = try JSONSerialization.data(withJSONObject: json)

        let decoded = try JSONDecoder().decode(EditDocument.self, from: data)
        XCTAssertEqual(decoded.camera, CameraStyle())
        XCTAssertEqual(decoded.style.padding, 0.1)
        XCTAssertEqual(decoded.zooms.count, 1)
        XCTAssertEqual(decoded.trimStartNs, 5)
    }

    func testCameraStyleRoundTrips() throws {
        var document = EditDocument()
        document.camera = CameraStyle(
            hidden: false, corner: .topLeft, size: 0.4,
            shape: .circle, margin: 0.05, zoomedScale: 1.0, mirrored: false)
        let data = try JSONEncoder().encode(document)
        let decoded = try JSONDecoder().decode(EditDocument.self, from: data)
        XCTAssertEqual(decoded.camera, document.camera)
        XCTAssertEqual(decoded.camera.corner, .topLeft)
        XCTAssertEqual(decoded.camera.shape, .circle)
        XCTAssertFalse(decoded.camera.mirrored)
    }
}

extension CameraStyleTests {
    /// Documents written before introNs existed decode to 0 (no intro);
    /// hostile values clamp to the 30 s ceiling.
    func testIntroNsDecodeToleranceAndClamp() throws {
        let legacy = Data("""
            {"hidden": false, "corner": "bottomRight", "size": 0.24,
             "shape": "rounded", "margin": 0.028, "zoomedScale": 0.7,
             "mirrored": true}
            """.utf8)
        let decoded = try JSONDecoder().decode(CameraStyle.self, from: legacy)
        XCTAssertEqual(decoded.introNs, 0)

        let hostile = Data("""
            {"introNs": 999000000000}
            """.utf8)
        let clamped = try JSONDecoder().decode(CameraStyle.self, from: hostile)
        XCTAssertEqual(clamped.introNs, 30_000_000_000)
        XCTAssertEqual(clamped.corner, .bottomRight)

        let negative = Data("""
            {"introNs": -5}
            """.utf8)
        XCTAssertEqual(
            try JSONDecoder().decode(CameraStyle.self, from: negative).introNs, 0)

        // Round-trip keeps the value.
        var style = CameraStyle()
        style.introNs = 5_000_000_000
        let redecoded = try JSONDecoder().decode(
            CameraStyle.self, from: JSONEncoder().encode(style))
        XCTAssertEqual(redecoded.introNs, 5_000_000_000)
    }
}

extension CameraStyleTests {
    /// Enum raw values from a NEWER build degrade to defaults instead of
    /// shunting the whole document to .corrupt-*.
    func testUnknownEnumRawValuesDecodeToDefaults() throws {
        let futuristic = Data("""
            {"corner": "center", "shape": "hexagon", "size": 0.3}
            """.utf8)
        let decoded = try JSONDecoder().decode(CameraStyle.self, from: futuristic)
        XCTAssertEqual(decoded.corner, .bottomRight)
        XCTAssertEqual(decoded.shape, .rounded)
        XCTAssertEqual(decoded.size, 0.3, accuracy: 0.0001)
    }
}
