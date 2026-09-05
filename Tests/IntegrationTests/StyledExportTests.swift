import AVFoundation
import CoreImage
import MotionEngine
import RenderGraph
import TimelineCore
import XCTest

@testable import CaptureCore
@testable import EventCapture
@testable import ExportEngine
@testable import PreviewEngine
@testable import ProjectModel
@testable import TimelineCore

final class StyledExportTests: XCTestCase {
    private var directory: URL!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("screenreel-styled-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    /// Full synthetic session with cursor/click events (so zooms generate).
    private func makeProject(durationNs: Int64) async throws -> URL {
        let projectURL = directory.appendingPathComponent("p-\(UUID().uuidString).screenreel")
        let configuration = CaptureConfiguration(
            widthPx: 320, heightPx: 180, nominalFrameRate: 30,
            videoCodec: .hevc, displayID: 1,
            microphoneEnabled: true, microphoneDeviceName: "Synthetic Microphone",
            segmentDurationSeconds: 4)
        let session = CaptureSession(projectURL: projectURL, configuration: configuration)
        let screen = SyntheticScreenSource(
            width: 320, height: 180, frameRate: 30, durationNs: durationNs, pace: 4)
        let mic = SyntheticAudioSource(channels: 1, durationNs: durationNs, pace: 4)
        try await session.start(screen: screen, microphone: mic, systemAudio: nil)

        let cursorTrackID = try await session.registerEventTrack(type: .cursorEvents)
        let clickTrackID = try await session.registerEventTrack(type: .clickEvents)
        let store = EventChunkStore(
            layout: session.projectLayout(),
            trackIDs: [.cursor: cursorTrackID, .clicks: clickTrackID],
            onCommit: { [session] chunk in
                try await session.commitEventChunk(chunk)
            })
        let (stream, continuation) = AsyncStream.makeStream(of: EventRecord.self)
        let events = SyntheticEventSource(
            durationNs: durationNs, widthPx: 320, heightPx: 180, pace: 4)
        events.start { record in continuation.yield(record) }
        let pump = Task {
            for await record in stream {
                try? await store.append(record)
            }
            try? await store.finish()
        }
        await screen.waitUntilFinished()
        await mic.waitUntilFinished()
        await events.waitUntilFinished()
        continuation.finish()
        await pump.value
        _ = try await session.stop()
        return projectURL
    }

    func testProjectCompositionEvaluatesFramesAndZooms() async throws {
        let projectURL = try await makeProject(durationNs: 8_000_000_000)
        let composition = try ProjectComposition(projectURL: projectURL)

        XCTAssertEqual(composition.sourceSize, SIMD2(320, 180))
        XCTAssertGreaterThan(composition.durationNs, 7_500_000_000)
        // Synthetic clicks every 2 s → auto zooms were generated and persisted.
        XCTAssertFalse(composition.edits.zooms.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: EditDocument.url(in: composition.layout).path))

        // Frames evaluate at arbitrary times, forward and backward.
        for timeNs: Int64 in [0, 3_000_000_000, 6_500_000_000, 1_000_000_000] {
            let frame = try await composition.frame(at: timeNs)
            XCTAssertNotNil(frame, "no frame at \(timeNs)")
        }
        // Cursor state exists and the camera zooms in somewhere.
        XCTAssertNotNil(composition.cursorState(at: 4_000_000_000))
        var sawZoom = false
        for timeNs in stride(from: Int64(0), to: 8_000_000_000, by: 250_000_000) {
            if composition.cameraState(at: timeNs).scale > 1.2 { sawZoom = true }
        }
        XCTAssertTrue(sawZoom, "camera never zoomed despite generated zoom segments")
    }

    func testStyledExportRendersEditsIntoValidatedMP4() async throws {
        let projectURL = try await makeProject(durationNs: 6_000_000_000)
        let outputURL = directory.appendingPathComponent("styled.mp4")

        let result = try await StyledExporter.export(
            projectAt: projectURL,
            to: outputURL,
            options: .init(fps: 30, outputHeight: 180, overwrite: false))

        // 6 s at 30 fps: the recording's logical end is lastPts + frame
        // duration, one integer-rounding tick short of exactly 6 s.
        XCTAssertEqual(result.videoFrames, 180)
        XCTAssertTrue(FileManager.default.fileExists(atPath: outputURL.path))

        let asset = AVURLAsset(url: outputURL)
        let duration = try await asset.load(.duration)
        XCTAssertEqual(duration.seconds, 6.0, accuracy: 0.25)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        XCTAssertEqual(audioTracks.count, 1)

        // The default style has padding + gradient background: a corner pixel
        // of a decoded frame must NOT be screen content. The synthetic screen
        // is mostly mid-grey with a white bar; the default gradient corner is
        // dark blue-ish. Decode the first frame and check.
        let reader = try AVAssetReader(asset: asset)
        let videoTrack = try await asset.loadTracks(withMediaType: .video)[0]
        let output = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ])
        reader.add(output)
        XCTAssertTrue(reader.startReading())
        let sample = try XCTUnwrap(output.copyNextSampleBuffer())
        let pixelBuffer = try XCTUnwrap(CMSampleBufferGetImageBuffer(sample))
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(pixelBuffer))
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let corner = base.assumingMemoryBound(to: UInt8.self)
        let blue = corner[2 * bytesPerRow + 2 * 4]  // BGRA: byte 0 = blue
        let red = corner[2 * bytesPerRow + 2 * 4 + 2]
        // Dark navy background: blue channel above red, both well below white.
        XCTAssertGreaterThan(blue, red)
        XCTAssertLessThan(red, 120)

        // Raw project untouched by the styled export.
        let report = await Validator(options: .init(verifyChecksums: true))
            .validate(projectAt: projectURL)
        XCTAssertTrue(report.isHealthy, "\(report.issues)")
    }

    func testStyledExportHonorsTrim() async throws {
        let projectURL = try await makeProject(durationNs: 8_000_000_000)
        let composition = try ProjectComposition(projectURL: projectURL)
        try composition.updateEdits { edits in
            edits.trimStartNs = 2_000_000_000
            edits.trimEndNs = 6_000_000_000
        }

        let outputURL = directory.appendingPathComponent("trimmed.mp4")
        let result = try await StyledExporter.export(
            projectAt: projectURL,
            to: outputURL,
            options: .init(fps: 30, outputHeight: 180))
        // ceil semantics: exactly 4 s × 30 fps = 120 frames — the old
        // floor+1 wrote one frame past the trimmed audio range.
        XCTAssertEqual(result.videoFrames, 120)  // exact 4 s range at 30 fps, inclusive frame 0

        let asset = AVURLAsset(url: outputURL)
        let duration = try await asset.load(.duration)
        XCTAssertEqual(duration.seconds, 4.0, accuracy: 0.25)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        let audioRange = try await audioTracks[0].load(.timeRange)
        XCTAssertEqual(audioRange.duration.seconds, 4.0, accuracy: 0.25)
    }
}

/// Export canvas sizing: the default output must render resting screen
/// content at exactly 1:1 source pixels (padding grows the canvas outward
/// rather than shrinking the content).
final class NativeContentSizingTests: XCTestCase {
    private func contentScale(sourceSize: SIMD2<Double>, style: FrameStyle) -> Double {
        let height = StyledExporter.nativeContentHeight(sourceSize: sourceSize, style: style)
        let aspect = style.canvasAspect ?? (sourceSize.x / sourceSize.y)
        let composer = FrameComposer(
            style: style,
            outputSize: SIMD2((height * aspect).rounded(), height.rounded()),
            sourceSize: sourceSize)
        return composer.geometry(camera: .identity).contentScale
    }

    func testDefaultPaddingYieldsUnitScale() {
        let scale = contentScale(
            sourceSize: SIMD2(4096, 2304), style: FrameStyle())
        XCTAssertEqual(scale, 1.0, accuracy: 0.002)
    }

    func testHeavyPaddingStillYieldsUnitScale() {
        let scale = contentScale(
            sourceSize: SIMD2(3840, 2160), style: FrameStyle(padding: 0.12))
        XCTAssertEqual(scale, 1.0, accuracy: 0.002)
    }

    func testZeroPaddingKeepsSourceSize() {
        let height = StyledExporter.nativeContentHeight(
            sourceSize: SIMD2(1920, 1080), style: .raw)
        XCTAssertEqual(height, 1080, accuracy: 0.5)
    }

    func testPortraitReframeStaysSane() {
        var style = FrameStyle()
        style.canvasAspect = 9.0 / 16.0
        let height = StyledExporter.nativeContentHeight(
            sourceSize: SIMD2(4096, 2304), style: style)
        // Bounded (portrait reframe of landscape content cannot reach 1:1
        // without an absurd canvas; the cap keeps exports reasonable).
        XCTAssertLessThanOrEqual(height, 2304 * 1.8 + 1)
        XCTAssertGreaterThan(height, 2303)
    }
}
