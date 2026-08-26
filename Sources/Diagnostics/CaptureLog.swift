import Foundation
import ProjectModel

/// Structured JSONL diagnostics for a capture session
/// (`diagnostics/capture.jsonl`). Non-critical by design: log writes are
/// buffered and never allowed to fail a recording; only redacted,
/// pixel/audio/key-free metadata is recorded (`docs/TECHNICAL_DESIGN.md` §10).
public actor CaptureLog {
    public enum Level: String, Codable, Sendable {
        case debug, info, warning, error
    }

    private let file: DurableAppendFile?
    private var buffer: [String] = []
    private let flushEvery: Int

    public init(url: URL, flushEvery: Int = 20) {
        self.file = try? DurableAppendFile(url: url)
        self.flushEvery = flushEvery
    }

    public func log(
        _ level: Level, _ event: String,
        timeNs: Int64, fields: [String: JSONValue] = [:]
    ) {
        var object = fields
        object["level"] = .string(level.rawValue)
        object["event"] = .string(event)
        object["timeNs"] = .integer(timeNs)
        object["wallTime"] = .string(RFC3339.now())
        guard let line = try? JSONValue.object(object).canonicalString() else { return }
        buffer.append(line)
        if buffer.count >= flushEvery || level == .error {
            flush()
        }
    }

    public func flush() {
        guard let file, !buffer.isEmpty else { return }
        let data = Data((buffer.joined(separator: "\n") + "\n").utf8)
        buffer.removeAll(keepingCapacity: true)
        try? file.append(data, durable: false)
    }
}
