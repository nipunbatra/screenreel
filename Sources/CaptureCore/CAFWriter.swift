import Foundation
import ProjectModel

/// Minimal CAF (Core Audio Format) writer for interleaved float32 LPCM.
///
/// CAF is the mandated raw-audio container (`docs/AUDIO_PIPELINE.md` §2)
/// because its `data` chunk may declare size -1 ("until EOF"): the header is
/// complete the moment the file is created, so even a torn tail from a power
/// loss remains a readable audio file. We keep -1 permanently and never seek
/// back, which also means a committed file is never rewritten.
public final class CAFWriter {
    public let url: URL
    public private(set) var framesWritten: Int = 0
    public let channels: Int
    public let sampleRate: Double

    private let handle: FileHandle

    public init(url: URL, sampleRate: Double, channels: Int) throws {
        self.url = url
        self.sampleRate = sampleRate
        self.channels = channels
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw AksError.ioFailed(operation: "create caf", path: url.path, errno: errno)
        }
        self.handle = try FileHandle(forWritingTo: url)
        try handle.write(contentsOf: Self.header(sampleRate: sampleRate, channels: channels))
    }

    /// Append interleaved float32 frames.
    public func append(samples: [Float]) throws {
        precondition(samples.count % channels == 0)
        var data = Data(capacity: samples.count * 4)
        for sample in samples {
            withUnsafeBytes(of: sample.bitPattern.littleEndian) { data.append(contentsOf: $0) }
        }
        try handle.write(contentsOf: data)
        framesWritten += samples.count / channels
    }

    /// Flush to stable storage and close. The file is final after this call.
    public func close() throws {
        try AtomicFile.sync(fileDescriptor: handle.fileDescriptor, path: url.path)
        try handle.close()
    }

    // MARK: - Header

    private static func header(sampleRate: Double, channels: Int) -> Data {
        var data = Data()
        // File header: 'caff', version 1, flags 0.
        data.append(fourCC("caff"))
        data.append(be16(1))
        data.append(be16(0))
        // Audio Description chunk.
        data.append(fourCC("desc"))
        data.append(be64(32))
        data.append(beDouble(sampleRate))
        data.append(fourCC("lpcm"))
        // Format flags: bit0 float, bit1 little-endian.
        data.append(be32(0b11))
        data.append(be32(UInt32(4 * channels)))  // bytes per packet
        data.append(be32(1))  // frames per packet
        data.append(be32(UInt32(channels)))
        data.append(be32(32))  // bits per channel
        // Data chunk with unknown size (-1) and edit count 0.
        data.append(fourCC("data"))
        data.append(be64(-1))
        data.append(be32(0))  // mEditCount
        return data
    }

    /// Byte offset where PCM starts; used to compute frame counts from file
    /// size when inspecting.
    public static let pcmDataOffset: Int64 = 8 + (12 + 32) + 12 + 4

    private static func fourCC(_ code: String) -> Data { Data(code.utf8) }

    private static func be16(_ value: UInt16) -> Data {
        withUnsafeBytes(of: value.bigEndian) { Data($0) }
    }

    private static func be32(_ value: UInt32) -> Data {
        withUnsafeBytes(of: value.bigEndian) { Data($0) }
    }

    private static func be64(_ value: Int64) -> Data {
        withUnsafeBytes(of: value.bigEndian) { Data($0) }
    }

    private static func beDouble(_ value: Double) -> Data {
        withUnsafeBytes(of: value.bitPattern.bigEndian) { Data($0) }
    }
}
