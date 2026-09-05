import CoreVideo
import Foundation
import ProjectModel
import XCTest
@testable import CaptureCore
@testable import PreviewEngine

final class StaticScreenTailTests: XCTestCase {
    func testSilentStaticScreenPersistsFullDurationWithoutContinuousFrames() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("screenreel-static-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let layout = ProjectLayout(root: root)
        for directory in layout.initialDirectories { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        actor Collected {
            var segments: [SegmentDescriptor] = []
            func add(_ segment: SegmentDescriptor) { segments.append(segment) }
        }
        let collected = Collected()
        let writer = VideoSegmentWriter(trackID: UUID(), settings: .screen(from: .init(widthPx: 160, heightPx: 90, microphoneEnabled: false)),
            layout: layout, onOpen: { _, _ in }, onCommit: { await collected.add($0) }, onFault: { _, _ in })
        var pixel: CVPixelBuffer?
        CVPixelBufferCreate(nil, 160, 90, kCVPixelFormatType_32BGRA, nil, &pixel)
        let first = VideoFrame(pixelBuffer: try XCTUnwrap(pixel), ptsNs: 0)
        try await writer.append(first)
        try await writer.finish(holdingLastFrameUntil: 10_000_000_000)
        let segments = await collected.segments
        XCTAssertEqual(segments.reduce(0) { $0 + ($1.video?.frameCount ?? 0) }, 1)
        XCTAssertEqual(segments.map(\.normalizedEndNs).max(), 10_000_000_000)
        let probe = await AVMediaInspector().probe(url: try layout.resolve(relativePath: segments[0].path), container: .mov)
        XCTAssertEqual(Double(probe.durationNs ?? 0), 10_000_000_000, accuracy: 20_000_000)
        let provider = try SegmentFrameProvider(segments: segments, layout: layout)
        let middle = try await provider.frame(at: 5_000_000_000)
        let end = try await provider.frame(at: 9_999_999_999)
        XCTAssertNotNil(middle)
        XCTAssertNotNil(end)
    }
}
