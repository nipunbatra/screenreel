import ArgumentParser
import CaptureCore
import Diagnostics
import Foundation

struct Env: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Print an environment report: OS, hardware, free disk, capturable displays.")

    @Flag(help: "Emit JSON.")
    var json = false

    struct Report: Codable {
        var environment: EnvironmentReport
        var displays: [DisplaySummary]

        struct DisplaySummary: Codable {
            var displayID: UInt32
            var pixels: String
            var points: String
        }
    }

    func run() async throws {
        let environment = EnvironmentReport.generate()
        let displays = (try? await SCKCapture.availableDisplays()) ?? []
        let report = Report(
            environment: environment,
            displays: displays.map {
                .init(
                    displayID: $0.displayID,
                    pixels: "\($0.widthPx)x\($0.heightPx)",
                    points: "\($0.widthPoints)x\($0.heightPoints)")
            })
        if json {
            try Output.json(report)
            return
        }
        print("Tool:     \(environment.toolVersion)")
        print("OS:       \(environment.osVersion)")
        print("Hardware: \(environment.hardwareModel) (\(environment.cpuBrand))")
        print("Memory:   \(Output.bytes(Int64(environment.physicalMemoryBytes)))")
        if let free = environment.freeDiskBytes {
            print("Free disk: \(Output.bytes(free))")
        }
        if displays.isEmpty {
            print("Displays: none visible (Screen Recording permission may be missing)")
        }
        for display in displays {
            print("Display \(display.displayID): \(display.widthPx)x\(display.heightPx) px (\(display.widthPoints)x\(display.heightPoints) pt)")
        }
    }
}
