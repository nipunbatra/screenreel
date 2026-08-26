import Foundation
import XCTest

@testable import TimelineCore

/// Per-field fallback strengthener: delete each optional key of a fully-populated
/// edit document, one at a time; decoding must succeed with ONLY that
/// field defaulting — a decoder that fails the whole document on one
/// missing key destroys real projects on the next schema addition.
final class PerFieldFallbackTests: XCTestCase {

    private func fullDocumentJSON() throws -> [String: Any] {
        var document = EditDocument(
            style: FrameStyle(padding: 0.09, canvasAspect: 16.0 / 9.0),
            cursor: CursorSettings(sizeMultiplier: 1.5),
            camera: CameraStyle(corner: .topLeft, size: 0.3),
            zooms: [ZoomSegment(startNs: 0, endNs: 1_000_000_000, scale: 2)],
            autoZoomEnabled: false,
            micNoiseReduction: true,
            trimStartNs: 100, trimEndNs: 900_000_000)
        document.schemaVersion = 1
        let data = try JSONEncoder().encode(document)
        return try JSONSerialization.jsonObject(with: data) as! [String: Any]
    }

    func testEachOptionalTopLevelKeyFallsBackOnItsOwn() throws {
        let optionalKeys = ["camera", "micNoiseReduction", "trimStartNs", "trimEndNs"]
        for key in optionalKeys {
            var json = try fullDocumentJSON()
            json.removeValue(forKey: key)
            let data = try JSONSerialization.data(withJSONObject: json)
            let decoded = try JSONDecoder().decode(EditDocument.self, from: data)
            // Every OTHER field survives.
            XCTAssertEqual(decoded.style.padding, 0.09, "key \(key)")
            XCTAssertEqual(decoded.cursor.sizeMultiplier, 1.5, "key \(key)")
            XCTAssertEqual(decoded.zooms.count, 1, "key \(key)")
            XCTAssertFalse(decoded.autoZoomEnabled, "key \(key)")
            switch key {
            case "camera":
                XCTAssertEqual(decoded.camera, CameraStyle(), "camera defaults")
            case "micNoiseReduction":
                XCTAssertFalse(decoded.micNoiseReduction, "legacy default off")
            case "trimStartNs":
                XCTAssertNil(decoded.trimStartNs)
                XCTAssertEqual(decoded.trimEndNs, 900_000_000)
            case "trimEndNs":
                XCTAssertNil(decoded.trimEndNs)
                XCTAssertEqual(decoded.trimStartNs, 100)
            default: break
            }
        }
    }

    func testStyleOptionalKeysFallBack() throws {
        var json = try fullDocumentJSON()
        var style = json["style"] as! [String: Any]
        style.removeValue(forKey: "canvasAspect")
        json["style"] = style
        let decoded = try JSONDecoder().decode(
            EditDocument.self,
            from: try JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(decoded.style.canvasAspect)
        XCTAssertEqual(decoded.style.padding, 0.09)
    }

    func testZoomOptionalKeysFallBack() throws {
        var json = try fullDocumentJSON()
        var zooms = json["zooms"] as! [[String: Any]]
        zooms[0].removeValue(forKey: "generatorVersion")
        zooms[0].removeValue(forKey: "disabled")
        json["zooms"] = zooms
        let decoded = try JSONDecoder().decode(
            EditDocument.self,
            from: try JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(decoded.zooms[0].generatorVersion)
        XCTAssertTrue(decoded.zooms[0].isActive)
    }
}
