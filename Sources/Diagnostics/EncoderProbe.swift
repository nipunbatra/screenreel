import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import ProjectModel

/// Result of the encoder capability probe, reported by `screenreel diagnose`.
public struct EncoderProbeResult: Codable, Sendable {
    public var passed: Bool
    public var codec: String
    public var width: Int
    public var height: Int
    public var encodedFrameCount: Int
    public var decodedFrameCount: Int
    public var meanLuma: Double?
    public var failureReason: String?
}

/// Encode/decode self-test: push a few mid-gray frames through AVAssetWriter /
/// VideoToolbox into a temp file, decode them back, and check the mean luma.
/// Catches "the encoder produces black or garbage frames" in `screenreel diagnose`,
/// before a real recording pays for it. Media never leaves the temp file and
/// the file is removed afterwards.
public enum EncoderCapabilityProbe {
    /// Mid-gray in, mid-gray out: the decoded mean luma must land in this
    /// band — generous enough for range/matrix conversion, far from black
    /// (0) or blown-out output.
    public static let acceptableMeanLuma: ClosedRange<Double> = 90...170

    public static func run(
        frameCount: Int = 10, width: Int = 320, height: Int = 180
    ) async -> EncoderProbeResult {
        var result = EncoderProbeResult(
            passed: false, codec: "h264", width: width, height: height,
            encodedFrameCount: 0, decodedFrameCount: 0,
            meanLuma: nil, failureReason: nil)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("screenreel-encoder-probe-\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: url) }
        do {
            result.encodedFrameCount = try await encodeGrayFrames(
                to: url, frameCount: frameCount, width: width, height: height)
            let decoded = try await decodeMeanLuma(of: url)
            result.decodedFrameCount = decoded.frames
            result.meanLuma = decoded.meanLuma
            guard decoded.frames == frameCount else {
                result.failureReason =
                    "decoded \(decoded.frames) of \(frameCount) encoded frames"
                return result
            }
            guard acceptableMeanLuma.contains(decoded.meanLuma) else {
                result.failureReason = String(
                    format: "decoded mean luma %.1f is outside %g...%g — the encoder "
                        + "did not reproduce the mid-gray frames it was given",
                    decoded.meanLuma,
                    acceptableMeanLuma.lowerBound, acceptableMeanLuma.upperBound)
                return result
            }
            result.passed = true
        } catch {
            result.failureReason = "\(error)"
        }
        return result
    }

    private enum ProbeError: Error, CustomStringConvertible {
        case setup(String)
        case encode(String)
        case decode(String)

        var description: String {
            switch self {
            case .setup(let why): return "encoder probe setup failed: \(why)"
            case .encode(let why): return "encoder probe encode failed: \(why)"
            case .decode(let why): return "encoder probe decode failed: \(why)"
            }
        }
    }

    private static func encodeGrayFrames(
        to url: URL, frameCount: Int, width: Int, height: Int
    ) async throws -> Int {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: width,
                AVVideoHeightKey: height,
            ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
            ])
        guard writer.canAdd(input) else {
            throw ProbeError.setup("writer refuses a \(width)x\(height) h264 video input")
        }
        writer.add(input)
        guard writer.startWriting() else {
            throw ProbeError.setup(
                "startWriting failed: \(writer.error.map { "\($0)" } ?? "unknown")")
        }
        writer.startSession(atSourceTime: .zero)

        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
            nil, &pixelBuffer)
        guard status == kCVReturnSuccess, let buffer = pixelBuffer else {
            throw ProbeError.setup("CVPixelBufferCreate failed (\(status))")
        }
        CVPixelBufferLockBaseAddress(buffer, [])
        if let base = CVPixelBufferGetBaseAddress(buffer) {
            // 0x80 in every BGRA byte: mid-gray.
            memset(base, 0x80, CVPixelBufferGetBytesPerRow(buffer) * CVPixelBufferGetHeight(buffer))
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])

        for index in 0..<frameCount {
            while !input.isReadyForMoreMediaData {
                try? await Task.sleep(nanoseconds: 2_000_000)
            }
            let time = CMTime(value: CMTimeValue(index), timescale: 30)
            guard adaptor.append(buffer, withPresentationTime: time) else {
                throw ProbeError.encode(
                    "append failed at frame \(index): \(writer.error.map { "\($0)" } ?? "unknown")")
            }
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw ProbeError.encode(
                "finishWriting ended in status \(writer.status.rawValue): "
                    + (writer.error.map { "\($0)" } ?? "unknown"))
        }
        return frameCount
    }

    private static func decodeMeanLuma(
        of url: URL
    ) async throws -> (frames: Int, meanLuma: Double) {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw ProbeError.decode("no video track in the probe output")
        }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String:
                    kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
            ])
        guard reader.canAdd(output) else {
            throw ProbeError.decode("reader refuses the track output")
        }
        reader.add(output)
        guard reader.startReading() else {
            throw ProbeError.decode(
                "startReading failed: \(reader.error.map { "\($0)" } ?? "unknown")")
        }
        var frames = 0
        var lumaSum = 0.0
        var lumaSamples = 0.0
        while let sample = output.copyNextSampleBuffer() {
            guard let buffer = CMSampleBufferGetImageBuffer(sample) else { continue }
            CVPixelBufferLockBaseAddress(buffer, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
            guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) else { continue }
            let bytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
            let planeWidth = CVPixelBufferGetWidthOfPlane(buffer, 0)
            let planeHeight = CVPixelBufferGetHeightOfPlane(buffer, 0)
            let plane = base.assumingMemoryBound(to: UInt8.self)
            var frameSum = 0
            for row in 0..<planeHeight {
                let rowBase = plane + row * bytesPerRow
                for column in 0..<planeWidth {
                    frameSum += Int(rowBase[column])
                }
            }
            lumaSum += Double(frameSum)
            lumaSamples += Double(planeWidth * planeHeight)
            frames += 1
        }
        if reader.status == .failed {
            throw ProbeError.decode(
                "reader failed: \(reader.error.map { "\($0)" } ?? "unknown")")
        }
        guard frames > 0, lumaSamples > 0 else {
            throw ProbeError.decode("no decodable frames in the probe output")
        }
        return (frames, lumaSum / lumaSamples)
    }
}
