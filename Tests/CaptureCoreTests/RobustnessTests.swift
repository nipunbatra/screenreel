import XCTest

@testable import CaptureCore
@testable import ProjectModel

private actor RobustnessCommitCollector {
    private(set) var descriptors: [SegmentDescriptor] = []

    func append(_ descriptor: SegmentDescriptor) {
        descriptors.append(descriptor)
    }
}

final class CaptureCoreRobustnessTests: XCTestCase {
    private var directory: URL!
    private var layout: ProjectLayout!

    override func setUp() {
        super.setUp()
        AtomicFile.fullFsync = false
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("screenreel-capture-robustness-\(UUID().uuidString).screenreel")
        layout = ProjectLayout(root: directory)
        for url in layout.initialDirectories {
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        AtomicFile.fullFsync = true
        super.tearDown()
    }

    func testAudioSegmentWriterRejectsZeroFrameSegmentThroughPublicAPI() async throws {
        let collector = RobustnessCommitCollector()
        let writer = AudioSegmentWriter(
            trackID: UUID(), trackType: .microphone, layout: layout,
            sampleRate: 48_000, channels: 1, segmentDurationNs: 2_000_000_000,
            onOpen: { _, _ in },
            onCommit: { descriptor in await collector.append(descriptor) })

        // A zero-frame chunk opens a real segment through the public API;
        // closing that segment must enforce the non-empty audio invariant.
        try await writer.append(AudioChunk(
            samples: [], frameCount: 0, channels: 1,
            sampleRate: 48_000, ptsNs: 0))
        do {
            try await writer.finish()
            XCTFail("zero-frame CAF segment unexpectedly committed")
        } catch let error as ScreenreelError {
            guard case .invariantViolated = error else {
                return XCTFail("expected invariantViolated, got \(error)")
            }
        }
        let committed = await collector.descriptors
        XCTAssertTrue(committed.isEmpty)
    }

    func testAVMediaInspectorRejectsCAFTruncatedInsideHeader() async throws {
        let url = directory.appendingPathComponent("short-header.caf")
        let writer = try CAFWriter(url: url, sampleRate: 48_000, channels: 1)
        try writer.append(samples: [Float](repeating: 0.25, count: 128))
        try writer.close()

        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: 40)
        try handle.close()
        XCTAssertLessThan(try Data(contentsOf: url).count, Int(CAFWriter.pcmDataOffset))

        let probe = await AVMediaInspector().probe(url: url, container: .caf)
        XCTAssertFalse(probe.decodable, "\(probe)")
    }

    func testAVMediaInspectorDoesNotAcceptCAFBytesAsMOV() async throws {
        let url = directory.appendingPathComponent("container-confusion.mov")
        let writer = try CAFWriter(url: url, sampleRate: 48_000, channels: 1)
        try writer.append(samples: [Float](repeating: 0.25, count: 480))
        try writer.close()

        let probe = await AVMediaInspector().probe(url: url, container: .mov)
        XCTAssertFalse(probe.decodable, "CAF content must not satisfy MOV video inspection")
        XCTAssertNil(probe.video)
    }
}
