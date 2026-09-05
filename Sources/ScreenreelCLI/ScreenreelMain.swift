import ArgumentParser
import Foundation

@main
struct Screenreel: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "screenreel",
        abstract: "Screen Reel — record, edit, export, and recover on your Mac.",
        discussion: """
            A .screenreel project is an open package: raw media under raw/, input events
            under events/, a hash-chained journal, and an atomically-replaced
            manifest. Record, export styled or original video, generate captions,
            inspect performance, validate, recover, and extract standard media.
            No account required. See docs/PROJECT_FORMAT.md.
            """,
        version: "0.2.0",
        subcommands: [
            Record.self, Export.self, Validate.self, Recover.self,
            Extract.self, Inspect.self, Env.self, Diagnose.self,
            Selftest.self, CaptionsExport.self, Perf.self,
        ])
}

enum CLIError: Error, CustomStringConvertible {
    case failed(String)
    var description: String {
        switch self {
        case .failed(let message): return message
        }
    }
}

enum Output {
    static func json<T: Encodable>(_ value: T) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(value)
        print(String(data: data, encoding: .utf8) ?? "{}")
    }

    static func duration(ns: Int64) -> String {
        let seconds = Double(ns) / 1_000_000_000
        if seconds < 60 { return String(format: "%.2f s", seconds) }
        let minutes = Int(seconds) / 60
        let rest = seconds - Double(minutes * 60)
        return String(format: "%d min %04.1f s", minutes, rest)
    }

    static func bytes(_ count: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: count)
    }
}

func projectURL(from path: String) -> URL {
    URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL
}
