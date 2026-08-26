import Foundation
import ProjectModel

/// One monotonic host clock for all streams (`docs/TECHNICAL_DESIGN.md` §3).
/// The anchor samples `mach_continuous_time` and `mach_absolute_time` at the
/// same instant; every event/sample timestamp is converted to signed
/// nanoseconds relative to this origin and both anchors are persisted in the
/// manifest so presentation times can be reproduced later.
public struct SessionClock: Sendable {
    public let anchor: ClockAnchor
    private let numer: UInt64
    private let denom: UInt64
    private let originContinuousNs: Int64
    private let originAbsoluteNs: Int64

    /// Capture a new origin (session start).
    public init() {
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        let continuous = mach_continuous_time()
        let absolute = mach_absolute_time()
        self.init(anchor: ClockAnchor(
            originContinuousTicks: continuous,
            originAbsoluteTicks: absolute,
            timebaseNumer: timebase.numer,
            timebaseDenom: timebase.denom,
            originWallTime: RFC3339.now()))
    }

    /// Rehydrate from a persisted anchor.
    public init(anchor: ClockAnchor) {
        self.anchor = anchor
        self.numer = UInt64(anchor.timebaseNumer)
        self.denom = UInt64(anchor.timebaseDenom)
        self.originContinuousNs = Self.ticksToNs(
            anchor.originContinuousTicks, numer: numer, denom: denom)
        self.originAbsoluteNs = Self.ticksToNs(
            anchor.originAbsoluteTicks, numer: numer, denom: denom)
    }

    /// Session-relative time now. Continuous time keeps advancing across
    /// sleep, so gaps are visible instead of silently compressed.
    public func nowNs() -> Int64 {
        Self.ticksToNs(mach_continuous_time(), numer: numer, denom: denom) - originContinuousNs
    }

    /// Normalize a host-clock (mach_absolute) nanosecond timestamp — the form
    /// carried by capture sample buffers and CGEvent timestamps.
    public func normalizeHostNs(_ hostNs: Int64) -> Int64 {
        hostNs - originAbsoluteNs
    }

    /// Normalize mach_absolute ticks.
    public func normalizeAbsoluteTicks(_ ticks: UInt64) -> Int64 {
        Self.ticksToNs(ticks, numer: numer, denom: denom) - originAbsoluteNs
    }

    private static func ticksToNs(_ ticks: UInt64, numer: UInt64, denom: UInt64) -> Int64 {
        // Split to avoid UInt64 overflow for large tick counts.
        let quotient = ticks / denom
        let remainder = ticks % denom
        return Int64(bitPattern: quotient &* numer &+ (remainder &* numer) / denom)
    }
}
