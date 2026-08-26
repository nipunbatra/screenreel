import Foundation
import ProjectModel
import TimelineCore

/// Camera pose at one frame time.
public struct CameraState: Sendable, Equatable {
    /// 1.0 = no zoom.
    public var scale: Double
    /// Screen-local normalized focal point.
    public var focal: SIMD2<Double>

    public init(scale: Double, focal: SIMD2<Double>) {
        self.scale = scale
        self.focal = focal
    }

    public static let identity = CameraState(scale: 1, focal: SIMD2(0.5, 0.5))
}

/// Deterministic screen-camera evaluation: the zoom targets drive one spring
/// (screen camera parameters), integrated once at 1 ms with 500 ms
/// checkpoints — identical machinery to the cursor so seek == play-through.
public final class CameraEngine: @unchecked Sendable {
    private let zooms: [ZoomSegment]
    private let durationNs: Int64
    private let spring: SpringParameters

    private struct Checkpoint {
        var scale: SpringState1D
        var focal: SpringState2D
    }

    private static let checkpointIntervalNs: Int64 = 500_000_000
    private let lock = NSLock()
    private var checkpoints: [Checkpoint]

    public init(
        zooms: [ZoomSegment],
        durationNs: Int64,
        spring: SpringParameters = .screenCamera
    ) {
        self.zooms = zooms.filter(\.isActive).sorted { $0.startNs < $1.startNs }
        self.durationNs = durationNs
        self.spring = spring
        let initialState: CameraState
        if let first = self.zooms.first, first.startNs <= 0, 0 < first.endNs {
            initialState = CameraState(
                scale: first.scale, focal: SIMD2(first.focalX, first.focalY))
        } else {
            initialState = .identity
        }
        self.checkpoints = [Checkpoint(
            scale: SpringState1D(value: initialState.scale),
            focal: SpringState2D(value: initialState.focal))]
    }

    public func state(at timeNs: Int64) -> CameraState {
        let clamped = max(0, min(timeNs, durationNs))
        let checkpoint = integratedCheckpoint(covering: clamped)
        var scale = checkpoint.scale
        var focal = checkpoint.focal
        let bucketStart = (clamped / Self.checkpointIntervalNs) * Self.checkpointIntervalNs
        integrate(from: bucketStart, to: clamped, scale: &scale, focal: &focal)
        return CameraState(scale: scale.value, focal: focal.value)
    }

    // MARK: - Integration

    private func integratedCheckpoint(covering timeNs: Int64) -> Checkpoint {
        lock.lock()
        defer { lock.unlock() }
        let bucket = Int(timeNs / Self.checkpointIntervalNs)
        while checkpoints.count <= bucket {
            let index = checkpoints.count - 1
            var scale = checkpoints[index].scale
            var focal = checkpoints[index].focal
            integrate(
                from: Int64(index) * Self.checkpointIntervalNs,
                to: Int64(index + 1) * Self.checkpointIntervalNs,
                scale: &scale, focal: &focal)
            checkpoints.append(Checkpoint(scale: scale, focal: focal))
        }
        return checkpoints[bucket]
    }

    /// Substep-grid integration with SEGMENT-WALKED targets: the target is
    /// constant between zoom boundaries, so it is resolved once per span
    /// instead of once per 1 ms substep. The stepped sequence (same grid,
    /// same target values) is bit-identical to the per-substep lookup —
    /// which made one deep seek on an hour-long timeline cost ~0.5 s and
    /// froze scrubbing (caught by SpringContinuityTests' cost bound).
    private func integrate(
        from startNs: Int64, to endNs: Int64,
        scale: inout SpringState1D, focal: inout SpringState2D
    ) {
        guard endNs > startNs else { return }
        var tau = startNs
        while tau < endNs {
            let span = targetSpan(at: tau)
            let spanEnd = min(span.endNs, endNs)
            if span.instant {
                // instant=true pins the state for the whole span (the
                // per-substep code re-assigned the same value each step).
                scale = SpringState1D(value: span.state.scale)
                focal = SpringState2D(value: span.state.focal)
                // Advance on the substep grid so tau stays grid-aligned.
                while tau < spanEnd { tau += SpringIntegrator.substepNs }
            } else {
                while tau < spanEnd {
                    SpringIntegrator.step(
                        &scale, target: span.state.scale,
                        parameters: spring, dt: SpringIntegrator.substepSeconds)
                    SpringIntegrator.step(
                        &focal, target: span.state.focal,
                        parameters: spring, dt: SpringIntegrator.substepSeconds)
                    tau += SpringIntegrator.substepNs
                }
            }
        }
    }

    /// The active target at `timeNs` and the time at which it next changes.
    /// Binary search over the sorted segments.
    private func targetSpan(
        at timeNs: Int64
    ) -> (state: CameraState, instant: Bool, endNs: Int64) {
        // First segment starting after timeNs (upper bound).
        var low = 0
        var high = zooms.count
        while low < high {
            let mid = (low + high) / 2
            if zooms[mid].startNs <= timeNs { low = mid + 1 } else { high = mid }
        }
        // The candidate active segment is the one before the upper bound.
        if low > 0 {
            let candidate = zooms[low - 1]
            if timeNs < candidate.endNs {
                // Inside a zoom; it ends at its own end or at the next
                // segment's start, whichever comes first.
                let next = low < zooms.count ? zooms[low].startNs : Int64.max
                return (
                    CameraState(
                        scale: candidate.scale,
                        focal: SIMD2(candidate.focalX, candidate.focalY)),
                    candidate.instant,
                    min(candidate.endNs, next))
            }
        }
        // In a gap: identity until the next segment starts.
        let next = low < zooms.count ? zooms[low].startNs : Int64.max
        return (.identity, false, next)
    }
}
