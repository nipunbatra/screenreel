import Foundation
import ProjectModel
import RenderGraph

// Milestone 3 interfaces (`docs/EXPORT_PIPELINE.md`, `docs/TECHNICAL_DESIGN.md`
// §8-9). Stub only in Milestone 0.

public struct ExportJob: Sendable {
    public var id: UUID
    public var snapshot: RenderSnapshot

    public init(id: UUID = UUID(), snapshot: RenderSnapshot) {
        self.id = id
        self.snapshot = snapshot
    }
}

public struct ExportProgress: Sendable {
    public var stage: String
    public var completedFrames: Int
    public var totalFrames: Int

    public init(stage: String, completedFrames: Int, totalFrames: Int) {
        self.stage = stage
        self.completedFrames = completedFrames
        self.totalFrames = totalFrames
    }
}

public protocol Exporting: Sendable {
    func start(_ job: ExportJob) async throws -> AsyncThrowingStream<ExportProgress, Error>
    func resume(jobID: UUID) async throws -> AsyncThrowingStream<ExportProgress, Error>
}
