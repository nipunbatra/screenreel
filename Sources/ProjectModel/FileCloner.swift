import Foundation

/// Copy-on-write file duplication. On APFS `clonefile(2)` is instant and uses
/// no extra space, which is what makes "recover a copy" cheap even for
/// multi-GB recordings; other filesystems fall back to a real copy.
public enum FileCloner {
    public static func clone(from source: URL, to destination: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let result = source.withUnsafeFileSystemRepresentation { src in
            destination.withUnsafeFileSystemRepresentation { dst in
                clonefile(src!, dst!, 0)
            }
        }
        if result == 0 { return }
        if errno == ENOTSUP || errno == EXDEV {
            try fm.copyItem(at: source, to: destination)
            return
        }
        throw AksError.ioFailed(operation: "clonefile", path: destination.path, errno: errno)
    }
}
