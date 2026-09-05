import CryptoKit
import Foundation

public enum Hashing {
    public static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Streamed SHA-256 of a file; segments are a few MB so 1 MiB chunks keep
    /// memory flat without measurable overhead.
    public static func sha256HexOfFile(at url: URL) throws -> String {
        guard let stream = InputStream(url: url) else {
            throw ScreenreelError.ioFailed(operation: "open for hash", path: url.path, errno: ENOENT)
        }
        stream.open()
        defer { stream.close() }
        var hasher = SHA256()
        let bufferSize = 1 << 20
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        while true {
            let read = stream.read(&buffer, maxLength: bufferSize)
            if read < 0 {
                throw ScreenreelError.ioFailed(operation: "read for hash", path: url.path, errno: EIO)
            }
            if read == 0 { break }
            hasher.update(data: Data(bytes: buffer, count: read))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
