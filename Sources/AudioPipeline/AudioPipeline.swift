import Foundation
import ProjectModel

// Milestone 2 interfaces (`docs/AUDIO_PIPELINE.md`). Stub only in Milestone 0:
// the denoiser is a job behind this boundary, never code in a render callback.

public struct EnhancementRequest: Sendable, Codable {
    public var rawAssetChecksums: [String]
    public var algorithmVersion: String
    public var modelChecksum: String?
    public var settings: [String: Double]

    public init(
        rawAssetChecksums: [String], algorithmVersion: String,
        modelChecksum: String? = nil, settings: [String: Double] = [:]
    ) {
        self.rawAssetChecksums = rawAssetChecksums
        self.algorithmVersion = algorithmVersion
        self.modelChecksum = modelChecksum
        self.settings = settings
    }
}

public protocol AudioEnhancing: Sendable {
    /// Produce a derived enhanced asset for the request, cached under
    /// `derived/audio-enhanced/`. Raw audio is never modified.
    func enhance(_ request: EnhancementRequest) async throws -> URL
}

/// Milestone 0 placeholder: always reports the feature as unavailable.
public struct UnimplementedAudioEnhancer: AudioEnhancing {
    public init() {}
    public func enhance(_ request: EnhancementRequest) async throws -> URL {
        throw ScreenreelError.invariantViolated(
            "Audio enhancement is not implemented in Milestone 0 (see docs/ROADMAP.md Milestone 2)")
    }
}
