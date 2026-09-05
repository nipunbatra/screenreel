import Darwin
import Foundation
import ProjectModel

/// One point of the per-second performance trace a recording writes to
/// `diagnostics/perf.jsonl`. Answers "what was the machine doing while I
/// recorded?" after the fact: our own CPU/RSS next to the whole system's
/// load and thermal state, so a laggy recording is diagnosable instead of
/// a vibe (`docs/TECHNICAL_DESIGN.md` §10 diagnostics).
public struct PerfSample: Codable, Sendable, Equatable {
    /// Host uptime at the sample (CLOCK_UPTIME_RAW nanoseconds).
    public var wallNs: Int64
    /// Interval this sample's rates cover; 0 for the baseline sample.
    public var intervalNs: Int64
    /// This process's CPU over the interval; 100 = one core fully busy.
    public var processCPUPercent: Double
    /// Whole-machine CPU over the interval; 100 = every core busy.
    public var systemCPUPercent: Double?
    public var residentBytes: Int64
    /// `ProcessInfo.ThermalState` name: nominal / fair / serious / critical.
    public var thermalState: String
    public var loadAverage1: Double

    public init(
        wallNs: Int64, intervalNs: Int64, processCPUPercent: Double,
        systemCPUPercent: Double?, residentBytes: Int64,
        thermalState: String, loadAverage1: Double
    ) {
        self.wallNs = wallNs
        self.intervalNs = intervalNs
        self.processCPUPercent = processCPUPercent
        self.systemCPUPercent = systemCPUPercent
        self.residentBytes = residentBytes
        self.thermalState = thermalState
        self.loadAverage1 = loadAverage1
    }

    public var fields: [String: JSONValue] {
        var object: [String: JSONValue] = [
            "wallNs": .integer(wallNs),
            "intervalNs": .integer(intervalNs),
            "processCPUPercent": .double((processCPUPercent * 10).rounded() / 10),
            "residentBytes": .integer(residentBytes),
            "thermalState": .string(thermalState),
            "loadAverage1": .double((loadAverage1 * 100).rounded() / 100),
        ]
        if let systemCPUPercent {
            object["systemCPUPercent"] = .double((systemCPUPercent * 10).rounded() / 10)
        }
        return object
    }
}

/// Stateful sampler: each `sample()` reports rates over the interval since
/// the previous call. Thread-safe (a lock guards the previous-sample state)
/// so an actor's heartbeat and a stop path may both call it.
public final class PerfSampler: @unchecked Sendable {
    private struct HostTicks: Equatable {
        var user: UInt64
        var system: UInt64
        var idle: UInt64
        var nice: UInt64
        var busy: UInt64 { user + system + nice }
        var total: UInt64 { busy + idle }
    }

    private let lock = NSLock()
    private var lastWallNs: Int64?
    private var lastProcessCPUNs: Int64?
    private var lastHostTicks: HostTicks?

    public init() {}

    public func sample() -> PerfSample {
        let nowNs = Int64(clock_gettime_nsec_np(CLOCK_UPTIME_RAW))
        let processCPUNs = Self.processCPUTimeNs()
        let hostTicks = Self.hostTicks()

        lock.lock()
        let previousWall = lastWallNs
        let previousCPU = lastProcessCPUNs
        let previousHost = lastHostTicks
        lastWallNs = nowNs
        lastProcessCPUNs = processCPUNs
        lastHostTicks = hostTicks
        lock.unlock()

        var intervalNs: Int64 = 0
        var processPercent = 0.0
        var systemPercent: Double?
        if let previousWall, let previousCPU, nowNs > previousWall {
            intervalNs = nowNs - previousWall
            processPercent = Double(max(0, processCPUNs - previousCPU))
                / Double(intervalNs) * 100
        }
        if let hostTicks, let previousHost, hostTicks.total > previousHost.total {
            let busy = Double(hostTicks.busy - previousHost.busy)
            let total = Double(hostTicks.total - previousHost.total)
            systemPercent = busy / total * 100
        }
        var loads = [Double](repeating: 0, count: 3)
        _ = getloadavg(&loads, 3)
        return PerfSample(
            wallNs: nowNs,
            intervalNs: intervalNs,
            processCPUPercent: processPercent,
            systemCPUPercent: systemPercent,
            residentBytes: Self.residentBytes(),
            thermalState: Self.thermalStateName(ProcessInfo.processInfo.thermalState),
            loadAverage1: loads[0])
    }

    // MARK: - Probes

    /// User + system CPU time consumed by this process so far.
    static func processCPUTimeNs() -> Int64 {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { return 0 }
        let user = Int64(usage.ru_utime.tv_sec) * 1_000_000_000 + Int64(usage.ru_utime.tv_usec) * 1000
        let system = Int64(usage.ru_stime.tv_sec) * 1_000_000_000 + Int64(usage.ru_stime.tv_usec) * 1000
        return user + system
    }

    private static func hostTicks() -> HostTicks? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return HostTicks(
            user: UInt64(info.cpu_ticks.0),
            system: UInt64(info.cpu_ticks.1),
            idle: UInt64(info.cpu_ticks.2),
            nice: UInt64(info.cpu_ticks.3))
    }

    static func residentBytes() -> Int64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return Int64(info.resident_size)
    }

    static func thermalStateName(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }
}

/// Whole-recording digest of the perf trace plus the pipeline counters the
/// session knows at stop (frames, drops, event-tap latency). Persisted as
/// `diagnostics/perf-summary.json` and shown to the operator.
public struct PerfSummary: Codable, Sendable, Equatable {
    public var samples: Int
    public var durationNs: Int64
    public var averageProcessCPUPercent: Double
    public var peakProcessCPUPercent: Double
    public var averageSystemCPUPercent: Double?
    public var peakSystemCPUPercent: Double?
    public var peakResidentBytes: Int64
    /// Worst thermal state seen (nominal < fair < serious < critical).
    public var worstThermalState: String
    /// Pipeline counters supplied by the session at stop (e.g. videoFrames,
    /// droppedVideoFrames, tapMaxCallbackUs, tapReenables).
    public var counters: [String: JSONValue]

    public init(
        samples: Int, durationNs: Int64,
        averageProcessCPUPercent: Double, peakProcessCPUPercent: Double,
        averageSystemCPUPercent: Double?, peakSystemCPUPercent: Double?,
        peakResidentBytes: Int64, worstThermalState: String,
        counters: [String: JSONValue]
    ) {
        self.samples = samples
        self.durationNs = durationNs
        self.averageProcessCPUPercent = averageProcessCPUPercent
        self.peakProcessCPUPercent = peakProcessCPUPercent
        self.averageSystemCPUPercent = averageSystemCPUPercent
        self.peakSystemCPUPercent = peakSystemCPUPercent
        self.peakResidentBytes = peakResidentBytes
        self.worstThermalState = worstThermalState
        self.counters = counters
    }

    private static let thermalRank = ["nominal": 0, "fair": 1, "serious": 2, "critical": 3]

    /// Interval-weighted digest; the zero-interval baseline sample counts
    /// for RSS/thermal but not for CPU rates.
    public static func summarize(
        _ samples: [PerfSample], counters: [String: JSONValue] = [:]
    ) -> PerfSummary {
        let rated = samples.filter { $0.intervalNs > 0 }
        let totalNs = rated.reduce(Int64(0)) { $0 + $1.intervalNs }
        func weightedAverage(_ value: (PerfSample) -> Double?) -> Double? {
            var sum = 0.0
            var weight: Int64 = 0
            for sample in rated {
                guard let v = value(sample) else { continue }
                sum += v * Double(sample.intervalNs)
                weight += sample.intervalNs
            }
            return weight > 0 ? sum / Double(weight) : nil
        }
        let worst = samples.map(\.thermalState).max {
            (thermalRank[$0] ?? -1) < (thermalRank[$1] ?? -1)
        } ?? "nominal"
        return PerfSummary(
            samples: samples.count,
            durationNs: totalNs,
            averageProcessCPUPercent: weightedAverage { $0.processCPUPercent } ?? 0,
            peakProcessCPUPercent: rated.map(\.processCPUPercent).max() ?? 0,
            averageSystemCPUPercent: weightedAverage { $0.systemCPUPercent },
            peakSystemCPUPercent: rated.compactMap(\.systemCPUPercent).max(),
            peakResidentBytes: samples.map(\.residentBytes).max() ?? 0,
            worstThermalState: worst,
            counters: counters)
    }

    /// One line for the operator, e.g.
    /// "avg CPU 24% (peak 61%) · system 38% · 410 MB · 0 dropped · tap max 0.4 ms".
    public var headline: String {
        var parts: [String] = []
        parts.append(String(
            format: "avg CPU %.0f%% (peak %.0f%%)",
            averageProcessCPUPercent, peakProcessCPUPercent))
        if let system = averageSystemCPUPercent, let peak = peakSystemCPUPercent {
            parts.append(String(format: "system %.0f%% (peak %.0f%%)", system, peak))
        }
        parts.append(String(format: "%.0f MB", Double(peakResidentBytes) / 1_048_576))
        if worstThermalState != "nominal" {
            parts.append("thermal \(worstThermalState)")
        }
        if let dropped = counters["droppedVideoFrames"]?.integerValue,
            let frames = counters["videoFrames"]?.integerValue
        {
            parts.append("\(frames) frames, \(dropped) dropped")
        }
        if let maxUs = counters["tapMaxCallbackUs"]?.integerValue {
            parts.append(String(format: "tap max %.1f ms", Double(maxUs) / 1000))
        }
        if let reenables = counters["tapReenables"]?.integerValue, reenables > 0 {
            parts.append("tap re-enabled \(reenables)×")
        }
        return parts.joined(separator: " · ")
    }

    /// Operator-facing problems worth a warning, empty when the recording
    /// ran clean.
    public var concerns: [String] {
        var out: [String] = []
        if let dropped = counters["droppedVideoFrames"]?.integerValue, dropped > 0 {
            out.append("\(dropped) video frame(s) dropped under encoder back-pressure")
        }
        if let buffers = counters["droppedBuffers"]?.integerValue, buffers > 0 {
            out.append("\(buffers) capture buffer(s) dropped (handoff overflow)")
        }
        if let reenables = counters["tapReenables"]?.integerValue, reenables > 0 {
            out.append("cursor event tap was disabled by macOS \(reenables)× and re-enabled (events may have gaps)")
        }
        if let maxUs = counters["tapMaxCallbackUs"]?.integerValue, maxUs > 20_000 {
            out.append(String(
                format: "cursor event tap callback peaked at %.0f ms (system input lag)",
                Double(maxUs) / 1000))
        }
        if let peak = peakSystemCPUPercent, peak >= 95 {
            out.append(String(format: "the whole machine hit %.0f%% CPU during the recording", peak))
        }
        if worstThermalState == "serious" || worstThermalState == "critical" {
            out.append("thermal state reached \(worstThermalState) (throttling likely)")
        }
        return out
    }
}
