import Foundation
import ProjectModel

// Milestone 1+ interfaces. Nothing here is implemented in Milestone 0; the
// types exist so package boundaries are real and later work cannot silently
// bypass them (CLAUDE.md: leave the editor behind interfaces/stubs).

/// Nanoseconds on the project timeline (post-edit time).
public struct TimelineTime: Sendable, Equatable, Comparable, Codable {
    public var ns: Int64
    public init(ns: Int64) { self.ns = ns }
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.ns < rhs.ns }
}

/// Maps project time to a source asset and source time
/// (`docs/TECHNICAL_DESIGN.md` §4). Implemented in Milestone 2.
public protocol TimeMapping: Sendable {
    func sourceTime(at time: TimelineTime) -> (trackID: UUID, sourceNs: Int64)?
}

/// Placeholder for the undoable edit model. Implemented in Milestone 2.
public protocol TimelineEditing: Sendable {}
