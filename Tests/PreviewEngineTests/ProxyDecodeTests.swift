import CoreImage
import Foundation
import ProjectModel
import XCTest

@testable import CaptureCore
@testable import PreviewEngine

/// Proxy decoding (`decodeMaxHeight`) makes 4K scrubbing cheap; these tests
/// pin the invariant that makes it legal: frames come back in SOURCE pixel
/// space regardless of decode resolution, so geometry and timing are
/// identical to a full-resolution decode (only sharpness differs).
final class ProxyDecodeTests: XCTestCase {

    private var root: URL!
    private var layout: ProjectLayout!
    private var segments: [SegmentDescriptor] = []

    override func setUp() async throws {
        try await super.setUp()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("screenreel-proxy-\(UUID().uuidString)")
        let projectURL = root.appendingPathComponent("p.screenreel")
        layout = ProjectLayout(root: projectURL)
        for directory in layout.initialDirectories {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
        }

        // Write one real 640×360 segment through the production writer.
        let configuration = CaptureConfiguration(
            widthPx: 640, heightPx: 360, nominalFrameRate: 30,
            videoCodec: .hevc, displayID: 1,
            microphoneEnabled: false, segmentDurationSeconds: 2)
        let collected = Collected()
        let writer = VideoSegmentWriter(
            trackID: UUID(), settings: .screen(from: configuration), layout: layout,
            onOpen: { _, _ in },
            onCommit: { descriptor in await collected.add(descriptor) },
            onFault: { _, _ in })
        var pixelBuffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, 640, 360, kCVPixelFormatType_32BGRA, nil, &pixelBuffer)
        let buffer = try XCTUnwrap(pixelBuffer)
        for index in 0..<30 {
            try await writer.append(VideoFrame(
                pixelBuffer: buffer,
                ptsNs: Int64(index) * 33_333_333))
        }
        try await writer.finish()
        segments = await collected.descriptors
        XCTAssertFalse(segments.isEmpty)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        segments = []
        super.tearDown()
    }

    private actor Collected {
        var descriptors: [SegmentDescriptor] = []
        func add(_ descriptor: SegmentDescriptor) { descriptors.append(descriptor) }
    }

    func testProxyFrameKeepsSourcePixelExtent() async throws {
        let provider = try SegmentFrameProvider(
            segments: segments, layout: layout, decodeMaxHeight: 180)
        let frame = try await provider.frame(at: 500_000_000)
        let image = try XCTUnwrap(frame)
        // Decoded at ≤180 px tall, but presented in source space: 640×360.
        XCTAssertEqual(image.extent.width, 640, accuracy: 1.5)
        XCTAssertEqual(image.extent.height, 360, accuracy: 1.5)
    }

    func testProxyAndFullProvidersReportIdenticalTiming() throws {
        let full = try SegmentFrameProvider(segments: segments, layout: layout)
        let proxy = try SegmentFrameProvider(
            segments: segments, layout: layout, decodeMaxHeight: 180)
        XCTAssertEqual(full.durationNs, proxy.durationNs)
        XCTAssertEqual(full.sourceSize, proxy.sourceSize)
    }

    func testProxyLargerThanSourceDecodesUntouched() async throws {
        // maxHeight above the source height must not upscale the decode.
        let provider = try SegmentFrameProvider(
            segments: segments, layout: layout, decodeMaxHeight: 4000)
        let frame = try await provider.frame(at: 100_000_000)
        let image = try XCTUnwrap(frame)
        XCTAssertEqual(image.extent.width, 640, accuracy: 0.5)
        XCTAssertEqual(image.extent.height, 360, accuracy: 0.5)
    }
}

extension ProxyDecodeTests {
    /// A capture that spun up late (first frame at t > 0) must still show
    /// that first frame for earlier times — not spin forever at t = 0.
    func testTimeBeforeFirstFrameClampsToFirstFrame() async throws {
        // Write a segment whose first frame lands at 0.5 s.
        let configuration = CaptureConfiguration(
            widthPx: 640, heightPx: 360, nominalFrameRate: 30,
            videoCodec: .hevc, displayID: 1,
            microphoneEnabled: false, segmentDurationSeconds: 2)
        let collected = Collected()
        let writer = VideoSegmentWriter(
            trackID: UUID(), settings: .screen(from: configuration), layout: layout,
            onOpen: { _, _ in },
            onCommit: { descriptor in await collected.add(descriptor) },
            onFault: { _, _ in })
        var pixelBufferOut: CVPixelBuffer?
        CVPixelBufferCreate(nil, 640, 360, kCVPixelFormatType_32BGRA, nil, &pixelBufferOut)
        let buffer = try XCTUnwrap(pixelBufferOut)
        for index in 0..<15 {
            try await writer.append(VideoFrame(
                pixelBuffer: buffer,
                ptsNs: 500_000_000 + Int64(index) * 33_333_333))
        }
        try await writer.finish()
        let lateSegments = await collected.descriptors
        XCTAssertEqual(lateSegments.first?.normalizedStartNs, 500_000_000)

        let provider = try SegmentFrameProvider(segments: lateSegments, layout: layout)
        let atZero = try await provider.frame(at: 0)
        XCTAssertNotNil(atZero, "t=0 before first frame must clamp, not spin")
        let atFirst = try await provider.frame(at: 500_000_000)
        XCTAssertNotNil(atFirst)
    }
}
