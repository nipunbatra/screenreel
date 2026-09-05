import ArgumentParser
import Diagnostics
import Foundation
import ProjectModel

struct Diagnose: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Environment report plus an encoder capability probe, redacted for sharing.",
        discussion: """
            Encodes and decodes a short mid-gray clip through VideoToolbox so
            "the encoder produces black frames" is caught here, not by a real
            recording. Every string in the output is redacted (home
            directories become ~, URL query values are elided), so the report
            is safe to attach to a bug report. Exits 2 when the probe fails.
            """)

    @Flag(help: "Emit JSON.")
    var json = false

    struct Report: Codable {
        var environment: EnvironmentReport
        var encoderProbe: EncoderProbeResult
    }

    func run() async throws {
        let probe = await EncoderCapabilityProbe.run()
        let report = try Redaction.redact(
            Report(environment: EnvironmentReport.generate(), encoderProbe: probe))
        if json {
            try Output.json(report)
        } else {
            printHuman(report)
        }
        if !report.encoderProbe.passed {
            throw ExitCode(2)
        }
    }

    private func printHuman(_ report: Report) {
        let environment = report.environment
        print("Tool:     \(environment.toolVersion)")
        print("OS:       \(environment.osVersion)")
        print("Hardware: \(environment.hardwareModel) (\(environment.cpuBrand))")
        print("Memory:   \(Output.bytes(Int64(environment.physicalMemoryBytes)))")
        if let free = environment.freeDiskBytes {
            print("Free disk: \(Output.bytes(free))")
        }
        let probe = report.encoderProbe
        let luma = probe.meanLuma.map { String(format: "%.1f", $0) } ?? "-"
        print("Encoder probe: \(probe.passed ? "PASS" : "FAIL") "
            + "(\(probe.codec) \(probe.width)x\(probe.height), "
            + "\(probe.decodedFrameCount)/\(probe.encodedFrameCount) frames decoded, "
            + "mean luma \(luma))")
        if let reason = probe.failureReason {
            print("  \(reason)")
        }
    }
}
