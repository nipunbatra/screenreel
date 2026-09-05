import ArgumentParser
import Diagnostics
import Foundation
import ProjectModel

/// Read the performance trace a recording left behind: "was the machine
/// struggling while I recorded?" answered from the project itself.
struct Perf: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Show a recording's performance digest (CPU, system load, drops, event-tap latency).",
        discussion: """
            Every recording writes diagnostics/perf.jsonl (one sample per second)
            and diagnostics/perf-summary.json. The digest reads the summary; --trace
            prints the per-second samples so a stutter can be placed in time.
            """)

    @Argument(help: "Path to the .aks project package.")
    var project: String

    @Flag(help: "Print the per-second samples.")
    var trace = false

    @Flag(help: "Emit the summary as JSON.")
    var json = false

    func run() async throws {
        let layout = ProjectLayout(root: projectURL(from: project))
        let summaryURL = layout.diagnosticsDirectory.appendingPathComponent("perf-summary.json")
        guard let data = try? Data(contentsOf: summaryURL) else {
            throw CLIError.failed(
                "no perf-summary.json in \(layout.diagnosticsDirectory.path) — recordings made before the perf trace existed, or a session that never stopped cleanly, have none")
        }
        let summary = try JSONDecoder().decode(PerfSummary.self, from: data)
        if json {
            try Output.json(summary)
            return
        }
        print("Performance: \(summary.headline)")
        print("Samples:     \(summary.samples) over \(Output.duration(ns: summary.durationNs))")
        if summary.concerns.isEmpty {
            print("Concerns:    none — the recording ran clean")
        } else {
            for concern in summary.concerns {
                print("CONCERN:     \(concern)")
            }
        }
        let known = Set([
            "videoFrames", "droppedVideoFrames", "droppedBuffers",
            "tapMaxCallbackUs", "tapReenables",
        ])
        let extras = summary.counters.filter { !known.contains($0.key) }.sorted { $0.key < $1.key }
        for (key, value) in extras {
            print("Counter:     \(key) = \(describe(value))")
        }
        guard trace else { return }

        let traceURL = layout.diagnosticsDirectory.appendingPathComponent("perf.jsonl")
        guard let text = try? String(contentsOf: traceURL, encoding: .utf8) else {
            print("(no perf.jsonl)")
            return
        }
        print("")
        print("     t   proc%   sys%    RSS  thermal  frames  drop   tapMax")
        var firstNs: Int64?
        for line in text.split(separator: "\n") {
            guard let object = try? JSONDecoder().decode(JSONValue.self, from: Data(line.utf8)),
                object["event"]?.stringValue == "perf"
            else { continue }
            let timeNs = object["timeNs"]?.integerValue ?? 0
            if firstNs == nil { firstNs = timeNs }
            let seconds = Double(timeNs - (firstNs ?? 0)) / 1e9
            let proc = object["processCPUPercent"]?.doubleValue ?? 0
            let sys = object["systemCPUPercent"]?.doubleValue
            let rss = Double(object["residentBytes"]?.integerValue ?? 0) / 1_048_576
            let thermal = object["thermalState"]?.stringValue ?? "?"
            let frames = object["videoFrames"]?.integerValue ?? 0
            let drops = object["droppedVideoFrames"]?.integerValue ?? 0
            let tapMax = object["tapMaxCallbackUs"]?.integerValue
            print(String(
                format: "%6.0fs  %5.0f  %5@  %5.0fM  %-8@ %6d  %4d  %@",
                seconds, proc,
                sys.map { String(format: "%.0f", $0) } ?? "-",
                rss, thermal, Int(frames), Int(drops),
                tapMax.map { String(format: "%.1fms", Double($0) / 1000) } ?? "-"))
        }
    }

    private func describe(_ value: JSONValue) -> String {
        switch value {
        case .integer(let i): return String(i)
        case .double(let d): return String(format: "%.2f", d)
        case .string(let s): return s
        case .bool(let b): return String(b)
        default: return (try? value.canonicalString()) ?? "?"
        }
    }
}
