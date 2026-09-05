import AVFoundation
import CoreImage
import XCTest

@testable import ExportEngine
@testable import PreviewEngine
@testable import ProjectModel

/// Opt-in golden check against a locally kept REAL recording
///: styled-export the pointed-at `.screenreel`
/// project, decode sampled frames, and require the preview composition to
/// match within a mean-abs-diff threshold. Real content exercises decoder
/// paths, cursor data, and zoom timing that synthetic fixtures cannot.
///
///   SCREENREEL_REAL_RECORDING_PATH=/path/to/recording.screenreel \
///     swift test --filter GoldenRealRecordingTests
final class GoldenRealRecordingTests: XCTestCase {
    private var directory: URL!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("screenreel-golden-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    func testSampledExportFramesMatchPreviewOnRealRecording() async throws {
        guard let path = ProcessInfo.processInfo.environment["SCREENREEL_REAL_RECORDING_PATH"],
            !path.isEmpty
        else {
            throw XCTSkip("set SCREENREEL_REAL_RECORDING_PATH=/path/to/recording.screenreel to run the golden check")
        }
        let projectURL = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        guard FileManager.default.fileExists(atPath: projectURL.path) else {
            throw XCTSkip("SCREENREEL_REAL_RECORDING_PATH does not exist: \(projectURL.path)")
        }

        let fps = 30.0
        let outputURL = directory.appendingPathComponent("golden.mp4")
        let result = try await StyledExporter.export(
            projectAt: projectURL,
            to: outputURL,
            options: .init(fps: fps, outputHeight: 360))
        XCTAssertGreaterThan(result.videoFrames, 0)

        // Sample early, middle, and late frames (clear of the first frame,
        // where a real recording's capture latency makes content ambiguous).
        let count = result.videoFrames
        let probeIndexes = Set([count / 10, count / 2, (count * 9) / 10]
            .map { max(1, min($0, count - 1)) })

        var exported: [Int: (pixels: [UInt8], width: Int, height: Int)] = [:]
        let asset = AVURLAsset(url: outputURL)
        let track = try await asset.loadTracks(withMediaType: .video)[0]
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ])
        reader.add(output)
        XCTAssertTrue(reader.startReading())
        var index = 0
        while let sample = output.copyNextSampleBuffer() {
            if probeIndexes.contains(index),
                let pixelBuffer = CMSampleBufferGetImageBuffer(sample)
            {
                exported[index] = Self.bytes(of: pixelBuffer)
            }
            index += 1
        }
        XCTAssertEqual(exported.count, probeIndexes.count)

        // Render the same times through the preview composition at the
        // exported size, mirroring the exporter's color pipeline.
        let (width, height) = try XCTUnwrap(exported.values.first.map { ($0.width, $0.height) })
        let composition = try ProjectComposition(projectURL: projectURL)
        composition.setOutputSize(SIMD2(Double(width), Double(height)))
        let context = CIContext(options: [.cacheIntermediates: false])
        let range = composition.trimmedRange

        for frameIndex in probeIndexes.sorted() {
            let timeNs = range.startNs + Int64(Double(frameIndex) / fps * 1e9)
            let composed = try await composition.frame(at: min(timeNs, range.endNs - 1))
            let image = try XCTUnwrap(composed, "no preview frame at index \(frameIndex)")
            var previewPixels = [UInt8](repeating: 0, count: width * height * 4)
            context.render(
                image, toBitmap: &previewPixels, rowBytes: width * 4,
                bounds: CGRect(x: 0, y: 0, width: width, height: height),
                format: .BGRA8,
                colorSpace: CGColorSpace(name: CGColorSpace.itur_709))
            let exportedPixels = try XCTUnwrap(exported[frameIndex]).pixels
            XCTAssertEqual(previewPixels.count, exportedPixels.count)

            // Looser than the synthetic parity gate: real content carries
            // real codec noise. A geometry/timing divergence still exceeds
            // these bounds by an order of magnitude.
            var totalError = 0
            var largeOutliers = 0
            for byteIndex in 0..<previewPixels.count {
                let error = abs(Int(previewPixels[byteIndex]) - Int(exportedPixels[byteIndex]))
                totalError += error
                if error > 64 { largeOutliers += 1 }
            }
            let mae = Double(totalError) / Double(previewPixels.count)
            let outlierFraction = Double(largeOutliers) / Double(previewPixels.count)
            print(String(
                format: "golden frame %d: MAE %.2f, outliers %.3f%%",
                frameIndex, mae, outlierFraction * 100))
            XCTAssertLessThan(
                mae, 12.0,
                "frame \(frameIndex): preview and export diverge on the real recording (MAE \(mae))")
            XCTAssertLessThan(
                outlierFraction, 0.03,
                "frame \(frameIndex): \(outlierFraction * 100)% large-error bytes — geometric divergence")
        }
    }

    private static func bytes(of pixelBuffer: CVPixelBuffer) -> (pixels: [UInt8], width: Int, height: Int) {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let base = CVPixelBufferGetBaseAddress(pixelBuffer)!.assumingMemoryBound(to: UInt8.self)
        var result = [UInt8](repeating: 0, count: width * height * 4)
        for row in 0..<height {
            for column in 0..<(width * 4) {
                result[row * width * 4 + column] = base[row * bytesPerRow + column]
            }
        }
        return (result, width, height)
    }
}
