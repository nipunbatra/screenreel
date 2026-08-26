import XCTest

@testable import Diagnostics

/// The encoder capability probe must pass on a healthy machine: mid-gray in,
/// mid-gray out, every frame accounted for. This is the check `aks diagnose`
/// runs so "the encoder produces black frames" surfaces before a recording.
final class EncoderProbeTests: XCTestCase {

    func testSmokeEncodeDecodePassesOnThisMachine() async {
        let result = await EncoderCapabilityProbe.run()
        XCTAssertTrue(result.passed, result.failureReason ?? "no reason reported")
        XCTAssertEqual(result.encodedFrameCount, 10)
        XCTAssertEqual(result.decodedFrameCount, 10)
        let luma = try? XCTUnwrap(result.meanLuma)
        XCTAssertNotNil(luma)
        if let luma {
            XCTAssertTrue(
                EncoderCapabilityProbe.acceptableMeanLuma.contains(luma),
                "mean luma \(luma) outside \(EncoderCapabilityProbe.acceptableMeanLuma)")
        }
        XCTAssertNil(result.failureReason)
    }
}
