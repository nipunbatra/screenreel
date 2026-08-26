import Foundation

/// Durable file primitives implementing `docs/PROJECT_FORMAT.md` §6:
/// JSON goes to a sibling `.tmp`, is flushed, renamed over the destination,
/// and the containing directory is flushed. `fullFsync` uses `F_FULLFSYNC`
/// so data reaches stable storage, not just the drive cache.
public enum AtomicFile {

    /// Whether durability barriers use `F_FULLFSYNC`. Tests may relax this for
    /// speed; production code paths leave it on.
    public nonisolated(unsafe) static var fullFsync = true

    /// `durable: false` skips the flush barriers but keeps the atomic
    /// tmp-then-rename replacement — for advisory data (heartbeats) whose
    /// loss on power failure is harmless by design.
    public static func write(_ data: Data, to destination: URL, durable: Bool = true) throws {
        let dir = destination.deletingLastPathComponent()
        let tmp = destination.appendingPathExtension("tmp")
        let fm = FileManager.default
        try? fm.removeItem(at: tmp)
        guard fm.createFile(atPath: tmp.path, contents: nil) else {
            throw AksError.ioFailed(operation: "create", path: tmp.path, errno: errno)
        }
        let handle = try FileHandle(forWritingTo: tmp)
        defer { try? handle.close() }
        try handle.write(contentsOf: data)
        if durable {
            try sync(fileDescriptor: handle.fileDescriptor, path: tmp.path)
        }
        try handle.close()

        try rename(from: tmp, to: destination)
        if durable {
            try syncDirectory(dir)
        }
    }

    public static func writeJSON<T: Encodable>(
        _ value: T, to destination: URL, durable: Bool = true
    ) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        let data = try encoder.encode(value)
        try write(data, to: destination, durable: durable)
    }

    /// POSIX rename: atomic replacement within a volume.
    public static func rename(from source: URL, to destination: URL) throws {
        let result = source.withUnsafeFileSystemRepresentation { src in
            destination.withUnsafeFileSystemRepresentation { dst in
                Foundation.rename(src!, dst!)
            }
        }
        guard result == 0 else {
            throw AksError.ioFailed(operation: "rename", path: destination.path, errno: errno)
        }
    }

    public static func syncDirectory(_ directory: URL) throws {
        let fd = open(directory.path, O_RDONLY)
        guard fd >= 0 else {
            throw AksError.ioFailed(operation: "open dir", path: directory.path, errno: errno)
        }
        defer { close(fd) }
        try sync(fileDescriptor: fd, path: directory.path)
    }

    public static func sync(fileDescriptor: Int32, path: String) throws {
        if fullFsync {
            if fcntl(fileDescriptor, F_FULLFSYNC) != 0 {
                // Some filesystems reject F_FULLFSYNC; fall back to fsync.
                guard fsync(fileDescriptor) == 0 else {
                    throw AksError.ioFailed(operation: "fsync", path: path, errno: errno)
                }
            }
        } else {
            guard fsync(fileDescriptor) == 0 else {
                throw AksError.ioFailed(operation: "fsync", path: path, errno: errno)
            }
        }
    }
}

/// Append-only file handle with explicit durability barriers, used by the
/// journal and diagnostics logs.
public final class DurableAppendFile: @unchecked Sendable {
    private let url: URL
    private let fd: Int32
    private let lock = NSLock()

    public init(url: URL) throws {
        self.url = url
        self.fd = url.withUnsafeFileSystemRepresentation { path in
            open(path!, O_WRONLY | O_APPEND | O_CREAT, 0o644)
        }
        guard fd >= 0 else {
            throw AksError.ioFailed(operation: "open append", path: url.path, errno: errno)
        }
    }

    /// Append bytes; when `durable`, block until they reach stable storage.
    public func append(_ data: Data, durable: Bool) throws {
        lock.lock()
        defer { lock.unlock() }
        try data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            var offset = 0
            while offset < buffer.count {
                let written = write(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    throw AksError.ioFailed(operation: "append", path: url.path, errno: errno)
                }
                offset += written
            }
        }
        if durable {
            try AtomicFile.sync(fileDescriptor: fd, path: url.path)
        }
    }

    public func synchronize() throws {
        lock.lock()
        defer { lock.unlock() }
        try AtomicFile.sync(fileDescriptor: fd, path: url.path)
    }

    deinit { close(fd) }
}
