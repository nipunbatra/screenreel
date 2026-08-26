import Foundation
import TimelineCore

// Reference spring integrator (`docs/MOTION_ENGINE.md` §4): semi-implicit
// Euler with fixed 1 ms substeps. All motion evaluation reduces to this one
// function so preview, export, and fixtures agree bit-for-bit.
// `SpringParameters` (the persisted values) live in TimelineCore.

public struct SpringState2D: Sendable, Equatable {
    public var value: SIMD2<Double>
    public var velocity: SIMD2<Double>

    public init(value: SIMD2<Double>, velocity: SIMD2<Double> = .zero) {
        self.value = value
        self.velocity = velocity
    }
}

public struct SpringState1D: Sendable, Equatable {
    public var value: Double
    public var velocity: Double

    public init(value: Double, velocity: Double = 0) {
        self.value = value
        self.velocity = velocity
    }
}

public enum SpringIntegrator {
    /// One reference substep (1 ms unless stated otherwise).
    @inline(__always)
    public static func step(
        _ state: inout SpringState2D, target: SIMD2<Double>,
        parameters: SpringParameters, dt: Double
    ) {
        let springForce = -(state.value - target) * parameters.stiffness
        let dampingForce = -state.velocity * parameters.damping
        let acceleration = (springForce + dampingForce) / parameters.mass
        state.velocity += acceleration * dt
        state.value += state.velocity * dt
    }

    @inline(__always)
    public static func step(
        _ state: inout SpringState1D, target: Double,
        parameters: SpringParameters, dt: Double
    ) {
        let springForce = -(state.value - target) * parameters.stiffness
        let dampingForce = -state.velocity * parameters.damping
        let acceleration = (springForce + dampingForce) / parameters.mass
        state.velocity += acceleration * dt
        state.value += state.velocity * dt
    }

    /// Reference substep duration: 1 ms.
    public static let substepNs: Int64 = 1_000_000
    public static let substepSeconds: Double = 0.001
}
