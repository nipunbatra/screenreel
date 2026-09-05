import Foundation
import ProjectModel

/// User-facing environment report for diagnostics bundles. Contains hardware,
/// OS, and free-space facts only — never screen pixels, audio, keys, or
/// unrelated filenames (`docs/TECHNICAL_DESIGN.md` §10).
public struct EnvironmentReport: Codable, Sendable {
    public var generatedAt: String
    public var toolVersion: String
    public var osVersion: String
    public var hardwareModel: String
    public var cpuBrand: String
    public var physicalMemoryBytes: UInt64
    public var freeDiskBytes: Int64?

    public static func generate(forVolumeContaining url: URL? = nil) -> EnvironmentReport {
        let process = ProcessInfo.processInfo
        var freeDisk: Int64?
        let volume = url ?? URL(fileURLWithPath: NSHomeDirectory())
        if let values = try? volume.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]) {
            freeDisk = values.volumeAvailableCapacityForImportantUsage
        }
        return EnvironmentReport(
            generatedAt: RFC3339.now(),
            toolVersion: ProjectSchema.toolVersion,
            osVersion: process.operatingSystemVersionString,
            hardwareModel: sysctlString("hw.model") ?? "unknown",
            cpuBrand: sysctlString("machdep.cpu.brand_string") ?? "unknown",
            physicalMemoryBytes: process.physicalMemory,
            freeDiskBytes: freeDisk)
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        let bytes = buffer.prefix { $0 != 0 }
        return String(decoding: bytes, as: UTF8.self)
    }
}
