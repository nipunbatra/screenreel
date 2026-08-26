import Foundation

/// Result of probing one media file. `decodable` means the container opened
/// and at least the first sample/packet decoded — the "basic decode
/// inspection" of `docs/PROJECT_FORMAT.md` §6.
public struct MediaProbe: Codable, Sendable {
    public var decodable: Bool
    public var durationNs: Int64?
    public var video: VideoFormatInfo?
    public var audio: AudioFormatInfo?
    public var issues: [String]

    public init(
        decodable: Bool,
        durationNs: Int64? = nil,
        video: VideoFormatInfo? = nil,
        audio: AudioFormatInfo? = nil,
        issues: [String] = []
    ) {
        self.decodable = decodable
        self.durationNs = durationNs
        self.video = video
        self.audio = audio
        self.issues = issues
    }
}

/// Injected by callers that can link AVFoundation (CaptureCore provides
/// `AVMediaInspector`). ProjectModel itself stays free of media frameworks so
/// the validator logic is testable with fakes.
public protocol MediaInspecting: Sendable {
    func probe(url: URL, container: MediaContainer) async -> MediaProbe
}
