import Foundation
import ProjectModel
import TimelineCore

/// Evaluated cursor state at one frame time, in captured source pixels.
public struct CursorFrameState: Sendable, Equatable {
    public var position: SIMD2<Double>
    /// Click squash scale (1.0 at rest).
    public var scale: Double
    public var cursorID: String?
    public var visible: Bool
    public var buttonDown: Bool
}

/// Deterministic cursor evaluation (`docs/MOTION_ENGINE.md` §3-4): a single
/// forward integration at 1 ms substeps with checkpoints every 500 ms, so a
/// random seek reproduces exactly the play-through state.
public final class CursorEngine: @unchecked Sendable {
    private let timeline: MotionTimeline
    private let settings: CursorSettings
    private let durationNs: Int64

    private struct Checkpoint {
        var position: SpringState2D
        var clickScale: SpringState1D
    }

    private static let checkpointIntervalNs: Int64 = 500_000_000
    private let lock = NSLock()
    private var checkpoints: [Checkpoint] = []

    public init(timeline: MotionTimeline, settings: CursorSettings, durationNs: Int64) {
        self.timeline = timeline
        self.settings = settings
        self.durationNs = durationNs
        if let start = timeline.targetPosition(at: 0) {
            checkpoints.append(Checkpoint(
                position: SpringState2D(value: start),
                clickScale: SpringState1D(value: 1)))
        }
    }

    /// Cursor state at `timeNs`, or nil when the project recorded no cursor.
    public func state(at timeNs: Int64) -> CursorFrameState? {
        guard !timeline.isEmpty else { return nil }
        guard settings.showCursor else { return nil }
        let clamped = max(0, min(timeNs, durationNs))

        let visible: Bool
        if let idle = settings.idleHideAfterNs,
            let lastMoveIndex = timeline.lastMoveIndex(at: clamped)
        {
            visible = clamped - timeline.moves[lastMoveIndex].timeNs < idle
        } else {
            visible = true
        }

        if !settings.smoothed {
            // Raw mode: recorded positions verbatim, squash still evaluated
            // analytically for click feedback.
            guard let target = timeline.targetPosition(at: clamped) else { return nil }
            return CursorFrameState(
                position: target,
                scale: rawSquashScale(at: clamped),
                cursorID: timeline.cursorID(at: clamped),
                visible: visible,
                buttonDown: timeline.isButtonDown(at: clamped))
        }

        let checkpoint = integratedCheckpoint(covering: clamped)
        var position = checkpoint.position
        var clickScale = checkpoint.clickScale
        let bucketStart = (clamped / Self.checkpointIntervalNs) * Self.checkpointIntervalNs
        integrate(from: bucketStart, to: clamped, position: &position, clickScale: &clickScale)

        return CursorFrameState(
            position: position.value,
            scale: clickScale.value,
            cursorID: timeline.cursorID(at: clamped),
            visible: visible,
            buttonDown: timeline.isButtonDown(at: clamped))
    }

    // MARK: - Deterministic integration

    /// Checkpoint state at the bucket containing `timeNs`, integrating and
    /// caching forward as needed. Buckets are only ever appended, so every
    /// checkpoint is the product of one canonical integration from t = 0.
    private func integratedCheckpoint(covering timeNs: Int64) -> Checkpoint {
        lock.lock()
        defer { lock.unlock() }
        let bucket = Int(timeNs / Self.checkpointIntervalNs)
        while checkpoints.count <= bucket {
            let index = checkpoints.count - 1
            var position = checkpoints[index].position
            var clickScale = checkpoints[index].clickScale
            let start = Int64(index) * Self.checkpointIntervalNs
            let end = Int64(index + 1) * Self.checkpointIntervalNs
            integrate(from: start, to: end, position: &position, clickScale: &clickScale)
            checkpoints.append(Checkpoint(position: position, clickScale: clickScale))
        }
        return checkpoints[bucket]
    }

    private func integrate(
        from startNs: Int64, to endNs: Int64,
        position: inout SpringState2D, clickScale: inout SpringState1D
    ) {
        guard endNs > startNs else { return }
        var tau = startNs
        while tau < endNs {
            let target = timeline.targetPosition(at: tau) ?? position.value
            let parameters = springParameters(at: tau)
            SpringIntegrator.step(
                &position, target: target,
                parameters: parameters, dt: SpringIntegrator.substepSeconds)
            SpringIntegrator.step(
                &clickScale, target: squashTarget(at: tau),
                parameters: settings.clickSpring, dt: SpringIntegrator.substepSeconds)
            tau += SpringIntegrator.substepNs
        }
    }

    /// Held while a button is down; quick-hop when the next movement target
    /// arrives within the quick-hop window; normal otherwise (spec §4).
    private func springParameters(at timeNs: Int64) -> SpringParameters {
        if timeline.isButtonDown(at: timeNs) {
            return settings.heldSpring
        }
        if let index = timeline.lastMoveIndex(at: timeNs),
            index + 1 < timeline.moves.count,
            timeline.moves[index + 1].timeNs - timeline.moves[index].timeNs
                <= settings.quickHopWindowNs
        {
            return settings.quickHopSpring
        }
        return settings.normalSpring
    }

    /// Squash target: toward `clickSquashScale` for the squash duration after
    /// a mouseDown, then back to 1.
    private func squashTarget(at timeNs: Int64) -> Double {
        guard let down = timeline.lastDown(at: timeNs) else { return 1 }
        return timeNs - down <= settings.clickSquashDurationNs
            ? settings.clickSquashScale : 1
    }

    /// Analytic squash approximation for raw (unsmoothed) mode.
    private func rawSquashScale(at timeNs: Int64) -> Double {
        guard let down = timeline.lastDown(at: timeNs) else { return 1 }
        let elapsed = timeNs - down
        let duration = settings.clickSquashDurationNs
        if elapsed <= duration {
            let progress = Double(elapsed) / Double(duration)
            return 1 - (1 - settings.clickSquashScale) * progress
        }
        let recovery = Double(elapsed - duration) / Double(duration)
        return min(1, settings.clickSquashScale + (1 - settings.clickSquashScale) * recovery)
    }
}
