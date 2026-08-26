import Foundation
import ProjectModel
import TimelineCore

// Milestone 1 interfaces (`docs/TECHNICAL_DESIGN.md` §5, §9). Stub only in
// Milestone 0. Preview and export must evaluate this same graph.

public struct RenderSnapshot: Sendable {
    public var schemaVersion: Int
    public var assetChecksums: [String]

    public init(schemaVersion: Int = AksSchema.currentVersion, assetChecksums: [String] = []) {
        self.schemaVersion = schemaVersion
        self.assetChecksums = assetChecksums
    }
}

/// Immutable render commands for one output frame.
public struct RenderCommands: Sendable {
    public init() {}
}

public protocol CompositionEvaluator: Sendable {
    func commands(at time: TimelineTime, in snapshot: RenderSnapshot) throws -> RenderCommands
}
