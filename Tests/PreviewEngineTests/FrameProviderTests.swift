import CoreImage
import CoreVideo
import XCTest

@testable import CaptureCore
@testable import PreviewEngine
@testable import ProjectModel

/// Deterministic random access over real encoded segments: every seek pattern
/// must return exactly the frame linear playback would show
/// (ACCEPTANCE_TESTS §3 seek determinism, applied at the provider layer).
final class FrameProviderTests: XCTestCase {
    private var directory: URL!
    private var layout: ProjectLayout!
    private var segments: [SegmentDescriptor] = []
    private let context = CIContext(options: [.workingColorSpace: NSNull()])

    actor Collector {
        var descriptors: [SegmentDescriptor] = []
        func add(_ descriptor: SegmentDescriptor) { descriptors.append(descriptor) }
    }

    override func setUp() async throws {
        try await super.setUp()
        AtomicFile.fullFsync = false
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("aks-provider-\(UUID().uuidString).aks")
        layout = ProjectLayout(root: directory)
        for dir in layout.initialDirectories {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }

        // 1 s of frames, an explicit discontinuity, then more frames starting
        // at 3 s — leaving a 2 s sparse hole in the middle.
        let configuration = CaptureConfiguration(
            widthPx: 160, heightPx: 90, nominalFrameRate: 30,
            videoCodec: .hevc, displayID: 1,
            microphoneEnabled: false, segmentDurationSeconds: 2)
        let collector = Collector()
        let writer = VideoSegmentWriter(
            trackID: UUID(), settings: .screen(from: configuration), layout: layout,
            onOpen: { _, _ in },
            onCommit: { descriptor in await collector.add(descriptor) },
            onFault: { _, _ in })
        for index in 0..<30 {
            try await writer.append(VideoFrame(
                pixelBuffer: Self.makeBuffer(shade: UInt8(20 + index * 2)),
                ptsNs: Int64(index) * 33_333_333))
        }
        await writer.markDiscontinuity()
        for index in 0..<30 {
            try await writer.append(VideoFrame(
                pixelBuffer: Self.makeBuffer(shade: UInt8(120 + index * 2)),
                ptsNs: 3_000_000_000 + Int64(index) * 33_333_333))
        }
        try await writer.finish()
        segments = await collector.descriptors.sorted { $0.sequenceInTrack < $1.sequenceInTrack }
        XCTAssertGreaterThanOrEqual(segments.count, 2)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        AtomicFile.fullFsync = true
        super.tearDown()
    }

    private static func makeBuffer(shade: UInt8) -> CVPixelBuffer {
        var bufferOut: CVPixelBuffer?
        CVPixelBufferCreate(
            nil, 160, 90, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey as String: [:]] as CFDictionary,
            &bufferOut)
        let buffer = bufferOut!
        CVPixelBufferLockBaseAddress(buffer, [])
        if let base = CVPixelBufferGetBaseAddress(buffer) {
            memset(base, Int32(shade), CVPixelBufferGetBytesPerRow(buffer) * 90)
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        return buffer
    }

    private func hash(_ image: CIImage) -> String {
        var pixels = [UInt8](repeating: 0, count: 160 * 90 * 4)
        context.render(
            image, toBitmap: &pixels, rowBytes: 160 * 4,
            bounds: CGRect(x: 0, y: 0, width: 160, height: 90),
            format: .BGRA8, colorSpace: nil)
        return Hashing.sha256Hex(Data(pixels))
    }

    func testRandomAccessMatchesLinearPlayback() async throws {
        let probeTimes: [Int64] = [
            0, 500_000_000, 966_666_657, 3_100_000_000, 3_900_000_000,
        ]

        // Linear pass.
        let linear = try SegmentFrameProvider(segments: segments, layout: layout)
        var linearHashes: [Int64: String] = [:]
        for timeNs in probeTimes.sorted() {
            let frame = try await linear.frame(at: timeNs)
            linearHashes[timeNs] = hash(try XCTUnwrap(frame, "no frame at \(timeNs)"))
        }

        // Fresh provider, adversarial order (backward seeks included).
        let random = try SegmentFrameProvider(segments: segments, layout: layout)
        for timeNs in [3_900_000_000, 500_000_000, 3_100_000_000, 0, 966_666_657] as [Int64] {
            let frame = try await random.frame(at: timeNs)
            XCTAssertEqual(
                hash(try XCTUnwrap(frame)), linearHashes[timeNs],
                "seek to \(timeNs) diverged from linear playback")
        }
    }

    func testSparseHoleShowsLastFrameBeforeIt() async throws {
        let provider = try SegmentFrameProvider(segments: segments, layout: layout)
        // Time inside the 1 s → 3 s hole must show the final pre-hole frame.
        let beforeFrame = try await provider.frame(at: 999_999_999)
        let holeFrame = try await provider.frame(at: 2_000_000_000)
        let afterFrame = try await provider.frame(at: 3_000_000_000)
        let lastBeforeHole = hash(try XCTUnwrap(beforeFrame))
        let inHole = hash(try XCTUnwrap(holeFrame))
        XCTAssertEqual(inHole, lastBeforeHole)
        // And the first post-hole time shows different content.
        let afterHole = hash(try XCTUnwrap(afterFrame))
        XCTAssertNotEqual(afterHole, inHole)
    }

    func testRepeatQueriesAreStable() async throws {
        let provider = try SegmentFrameProvider(segments: segments, layout: layout)
        let firstFrame = try await provider.frame(at: 700_000_000)
        let secondFrame = try await provider.frame(at: 700_000_000)
        let nudgedFrame = try await provider.frame(at: 710_000_000)
        let first = hash(try XCTUnwrap(firstFrame))
        let second = hash(try XCTUnwrap(secondFrame))
        let nudged = hash(try XCTUnwrap(nudgedFrame))
        XCTAssertEqual(first, second)
        XCTAssertEqual(first, nudged)  // same source frame within one interval
    }

    func testDurationAndSourceSizeComeFromDescriptors() throws {
        let provider = try SegmentFrameProvider(segments: segments, layout: layout)
        XCTAssertEqual(provider.sourceSize, SIMD2(160, 90))
        XCTAssertEqual(
            Double(provider.durationNs) / 1e9, 4.0, accuracy: 0.05)
    }
}
