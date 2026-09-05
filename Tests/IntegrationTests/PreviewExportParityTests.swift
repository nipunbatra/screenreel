import AVFoundation
import CoreImage
import XCTest

@testable import ExportEngine
@testable import PreviewEngine
@testable import ProjectModel

/// THE core invariant (CLAUDE.md / ACCEPTANCE_TESTS §3): preview and export
/// evaluate the same composition. The preview path renders frames through
/// `ProjectComposition`; the styled exporter's decoded output must match
/// those frames pixel-for-pixel within codec tolerance.
final class PreviewExportParityTests: XCTestCase {
    private var directory: URL!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("screenreel-parity-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    func testStyledExportMatchesPreviewComposition() async throws {
        let projectURL = try await SyntheticProjectFactory.make(
            in: directory, durationNs: 6_000_000_000)
        let outputURL = directory.appendingPathComponent("parity.mp4")

        // Export with a generous bitrate so codec error stays small and any
        // real divergence (geometry, zoom, cursor, timing) stands out.
        let fps = 30.0
        let result = try await StyledExporter.export(
            projectAt: projectURL,
            to: outputURL,
            options: .init(
                fps: fps, bitsPerPixelPerFrame: 1.0, outputHeight: 180))
        XCTAssertGreaterThan(result.videoFrames, 100)

        // Decode selected exported frames (BGRA), keyed by frame index.
        let probeIndexes: Set<Int> = [5, 60, 130]
        var exported: [Int: [UInt8]] = [:]
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

        // Render the same frame times through the preview composition at the
        // exact export output size.
        let composition = try ProjectComposition(projectURL: projectURL)
        let width = 320
        let height = 180
        composition.setOutputSize(SIMD2(Double(width), Double(height)))
        // Mirror the exporter's context exactly (color-managed, default
        // working space): the reference must go through the same color
        // pipeline as the file, or transfer-curve differences masquerade
        // as composition divergence.
        let context = CIContext(options: [.cacheIntermediates: false])
        let range = composition.trimmedRange

        for frameIndex in probeIndexes.sorted() {
            let timeNs = range.startNs + Int64(Double(frameIndex) / fps * 1e9)
            let composed = try await composition.frame(
                at: min(timeNs, range.endNs - 1))
            let image = try XCTUnwrap(composed)
            var previewPixels = [UInt8](repeating: 0, count: width * height * 4)
            context.render(
                image, toBitmap: &previewPixels, rowBytes: width * 4,
                bounds: CGRect(x: 0, y: 0, width: width, height: height),
                format: .BGRA8,
                // Same output space as the exporter (BT.709): the gate
                // compares geometry/content, not transfer curves.
                colorSpace: CGColorSpace(name: CGColorSpace.itur_709))
            let exportedPixels = try XCTUnwrap(exported[frameIndex])
            XCTAssertEqual(previewPixels.count, exportedPixels.count)

            // Two complementary bounds:
            // - mean absolute error small (codec quantization noise only);
            // - almost no large-outlier bytes. A geometry/timing divergence
            //   (zoom offset, wrong source frame) lights up entire edges with
            //   large errors and fails the outlier bound decisively.
            var totalError = 0
            var largeOutliers = 0
            for byteIndex in 0..<previewPixels.count {
                let error = abs(Int(previewPixels[byteIndex]) - Int(exportedPixels[byteIndex]))
                totalError += error
                if error > 64 { largeOutliers += 1 }
            }
            let mae = Double(totalError) / Double(previewPixels.count)
            let outlierFraction = Double(largeOutliers) / Double(previewPixels.count)
            XCTAssertLessThan(
                mae, 8.0,
                "frame \(frameIndex): preview and export diverge (MAE \(mae))")
            XCTAssertLessThan(
                outlierFraction, 0.01,
                "frame \(frameIndex): \(outlierFraction * 100)% large-error bytes — geometric divergence")
        }
    }

    private static func bytes(of pixelBuffer: CVPixelBuffer) -> [UInt8] {
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
        return result
    }
}
