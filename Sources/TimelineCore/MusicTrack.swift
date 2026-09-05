import Foundation
import ProjectModel

/// One portable music asset on the output timeline (independent of source cuts).
public struct BackgroundMusic: Codable, Sendable, Equatable {
    public var path: String
    public var originalPath: String
    public var name: String
    public var volume: Double
    public var loops: Bool

    public init(path: String, originalPath: String, name: String,
                volume: Double = 0.2, loops: Bool = true) {
        self.path = path
        self.originalPath = originalPath
        self.name = name
        self.volume = volume
        self.loops = loops
    }

    public var gain: Float { volume.isFinite ? Float(min(1, max(0, volume))) : 0 }

    public func audioURL(in layout: ProjectLayout) throws -> URL {
        let url = try layout.resolve(relativePath: path)
        let directory = layout.root.appendingPathComponent("assets/music").resolvingSymlinksInPath()
        guard path.hasPrefix("assets/music/"),
              url.resolvingSymlinksInPath().path.hasPrefix(directory.path + "/"),
              directory.path.hasPrefix(layout.root.resolvingSymlinksInPath().path + "/")
        else {
            throw ScreenreelError.invariantViolated("music must be a file inside this project's assets/music folder")
        }
        return url
    }

    /// Same origin in preview and export, including seeks and trimmed output.
    public func sourceFrame(at outputFrame: Int64, length: Int64) -> Int64? {
        guard outputFrame >= 0, length > 0 else { return nil }
        return loops ? outputFrame % length : (outputFrame < length ? outputFrame : nil)
    }
}
