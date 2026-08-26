import Foundation
import RenderGraph
import TimelineCore

// Milestone 1 interface. Stub only in Milestone 0.

public enum PreviewQuality: String, Sendable {
    case accurate, responsive, powerSaving
}

public protocol PreviewRendering: Sendable {
    func seek(to time: TimelineTime) async
    var quality: PreviewQuality { get }
}
