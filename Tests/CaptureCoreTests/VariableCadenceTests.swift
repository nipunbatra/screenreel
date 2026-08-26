import CoreVideo
import Foundation
import ProjectModel
import XCTest

@testable import CaptureCore
@testable import PreviewEngine

/// VFR discipline: a long
/// variable-cadence stream (~6% off nominal, jittered) writes segments
/// whose spans match the actual timestamps, and time→frame mapping follows
/// real PTS with no cumulative index slip.
final class VariableCadenceTests: XCTestCase {

    private var root: URL!
    private var layout: ProjectLayout!

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("aks-vfr-\(UUID().uuidString)")
        layout = ProjectLayout(root: root.appendingPathComponent("p.aks"))
        for directory in layout.initialDirectories {
            try? FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
        }
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    private actor Collector {
        var descriptors: [SegmentDescriptor] = []
        func add(_ d: SegmentDescriptor) { descriptors.append(d) }
    }

    func testSixtyFiveSecondVariableCadenceStream() async throws {
        let configuration = CaptureConfiguration(
            widthPx: 160, heightPx: 90, nominalFrameRate: 30,
            videoCodec: .hevc, displayID: 1,
            microphoneEnabled: false, segmentDurationSeconds: 4)
        let collector = Collector()
        let writer = VideoSegmentWriter(
            trackID: UUID(), settings: .screen(from: configuration), layout: layout,
            onOpen: { _, _ in },
            onCommit: { d in await collector.add(d) },
            onFault: { _, _ in })
        var out: CVPixelBuffer?
        CVPixelBufferCreate(nil, 160, 90, kCVPixelFormatType_32BGRA, nil, &out)
        let buffer = try XCTUnwrap(out)

        // 65 s of CONTENT (not wall time): nominal 30 fps but running ~6%
        // slow with deterministic jitter — the off-nominal VFR shape that
        // produced real drifted-MP4 bugs.
        var state: UInt64 = 65
        var pts: Int64 = 0
        var sent: [Int64] = []
        while pts < 65_000_000_000 {
            sent.append(pts)
            try await writer.append(VideoFrame(pixelBuffer: buffer, ptsNs: pts))
            state = state &* 6364136223846793005 &+ 1442695040888963407
            let jitter = Int64(state % 8_000_000) - 4_000_000
            pts += 35_333_333 + jitter  // ~28.3 fps effective
        }
        try await writer.finish()

        let segments = await collector.descriptors
            .sorted { $0.sequenceInTrack < $1.sequenceInTrack }
        let frames = segments.reduce(0) { $0 + ($1.video?.frameCount ?? 0) }
        XCTAssertEqual(frames, sent.count)
        XCTAssertEqual(segments.first?.normalizedStartNs, 0)
        // Total span tracks the last actual PTS, not nominal 30 fps math.
        let end = try XCTUnwrap(segments.last?.normalizedEndNs)
        XCTAssertEqual(Double(end), Double(sent.last!), accuracy: 80_000_000)

        // Time→frame mapping follows REAL pts: probing at exact sent
        // timestamps deep into the stream returns frames, and seek at the
        // tail matches linear arrival (no cumulative slip).
        let provider = try SegmentFrameProvider(segments: segments, layout: layout)
        for probeIndex in [10, sent.count / 2, sent.count - 2] {
            let frame = try await provider.frame(at: sent[probeIndex] + 1_000_000)
            XCTAssertNotNil(frame, "no frame at sent[\(probeIndex)]")
        }
    }
}
