import AVFoundation
import Foundation
import ProjectModel
import Speech

/// On-device transcription of a project's microphone track. Requires the
/// user's one-time Speech Recognition authorization; everything runs
/// locally (`requiresOnDeviceRecognition`), nothing leaves the machine.
public enum Transcriber {

    public enum TranscriberError: Error, CustomStringConvertible {
        case notAuthorized
        case unsupportedLocale(String)
        case recognitionFailed(String)

        public var description: String {
            switch self {
            case .notAuthorized:
                return "Speech recognition is not authorized. Approve it in the system prompt (or System Settings → Privacy & Security → Speech Recognition)."
            case .unsupportedLocale(let locale):
                return "On-device speech recognition is unavailable for locale \(locale). Download the language in System Settings → Keyboard → Dictation."
            case .recognitionFailed(let message):
                return "Transcription failed: \(message)"
            }
        }
    }

    public static func requestAuthorization() async -> Bool {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
    }

    /// Transcribe every microphone segment; cue times are SOURCE time
    /// (each segment's file time + its normalized start).
    /// One segment's recognition as a cancellable async call: cancelling
    /// the task cancels the SFSpeech task, whose error callback resumes the
    /// continuation — the watchdog can always unwind.
    private struct RecognitionHandles: @unchecked Sendable {
        let request: SFSpeechURLRecognitionRequest
        let recognizer: SFSpeechRecognizer
    }

    private static func recognize(
        handles: RecognitionHandles
    ) async throws -> [(text: String, timestamp: Double, duration: Double)] {
        final class TaskHolder: @unchecked Sendable {
            private let lock = NSLock()
            private var task: SFSpeechRecognitionTask?
            private var cancelled = false
            /// If cancellation raced ahead of task creation, cancel the
            /// task immediately on arrival — otherwise nothing ever would.
            func set(_ new: SFSpeechRecognitionTask) {
                lock.lock()
                task = new
                let wasCancelled = cancelled
                lock.unlock()
                if wasCancelled { new.cancel() }
            }
            func cancel() {
                lock.lock()
                cancelled = true
                let current = task
                lock.unlock()
                current?.cancel()
            }
        }
        let holder = TaskHolder()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                var finished = false
                // Extract Sendable data inside the callback: the result
                // object itself may not cross the continuation.
                let task = handles.recognizer.recognitionTask(
                    with: handles.request
                ) { result, error in
                    guard !finished else { return }
                    if let error {
                        finished = true
                        continuation.resume(
                            throwing: TranscriberError.recognitionFailed("\(error)"))
                    } else if let result, result.isFinal {
                        finished = true
                        continuation.resume(
                            returning: result.bestTranscription.segments.map {
                                ($0.substring, $0.timestamp, $0.duration)
                            })
                    }
                }
                holder.set(task)
            }
        } onCancel: {
            holder.cancel()
        }
    }

    public static func transcribeMicTrack(
        segments: [SegmentDescriptor],
        layout: ProjectLayout,
        locale: Locale = Locale(identifier: "en-US"),
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> [CaptionCue] {
        guard SFSpeechRecognizer.authorizationStatus() == .authorized else {
            throw TranscriberError.notAuthorized
        }
        guard let recognizer = SFSpeechRecognizer(locale: locale),
            recognizer.supportsOnDeviceRecognition
        else {
            throw TranscriberError.unsupportedLocale(locale.identifier)
        }

        let ordered = segments.sorted { $0.sequenceInTrack < $1.sequenceInTrack }
        var cues: [CaptionCue] = []
        var failures = 0
        for (index, segment) in ordered.enumerated() {
            let url = try layout.resolve(relativePath: segment.path)
            let request = SFSpeechURLRecognitionRequest(url: url)
            request.requiresOnDeviceRecognition = true
            request.shouldReportPartialResults = false
            request.taskHint = .dictation

            // A silent or unreadable segment loses ITS minute, never the
            // whole lecture: recognition errors — including the watchdog
            // timeout — skip the segment.
            let pieces: [(text: String, timestamp: Double, duration: Double)]
            do {
                // Watchdog: 4× the segment's real duration (min 2 min).
                // Speech normally errors or finals, but a hung recognizer
                // must not pin isTranscribing forever.
                let segmentSeconds = min(
                    86_400.0,
                    Double(max(0, segment.normalizedEndNs - segment.normalizedStartNs))
                        / 1e9)  // clamp: corrupt descriptors must not trap UInt64
                let timeoutNs = UInt64(max(120.0, segmentSeconds * 4) * 1e9)
                // SFSpeech types are not Sendable; recognition task
                // creation is thread-safe and the request is consumed by
                // exactly one task, so the transfer is sound.
                let handles = RecognitionHandles(
                    request: request, recognizer: recognizer)
                pieces = try await withThrowingTaskGroup(
                    of: [(text: String, timestamp: Double, duration: Double)].self
                ) { group in
                    group.addTask {
                        try await Self.recognize(handles: handles)
                    }
                    group.addTask {
                        try await Task.sleep(nanoseconds: timeoutNs)
                        throw TranscriberError.recognitionFailed(
                            "segment timed out after \(Int(Double(timeoutNs) / 1e9)) s")
                    }
                    guard let first = try await group.next() else {
                        throw TranscriberError.recognitionFailed("no result")
                    }
                    group.cancelAll()
                    return first
                }
            } catch {
                failures += 1
                progress?(Double(index + 1) / Double(ordered.count))
                continue
            }

            let base = segment.normalizedStartNs
            for piece in pieces {
                let start = base + Int64(piece.timestamp * 1e9)
                let end = start + Int64(piece.duration * 1e9)
                cues.append(CaptionCue(startNs: start, endNs: end, text: piece.text))
            }
            progress?(Double(index + 1) / Double(ordered.count))
        }
        if failures == ordered.count, failures > 0 {
            throw TranscriberError.recognitionFailed(
                "all \(failures) microphone segments failed to transcribe")
        }
        return CaptionWriter.shaped(cues)
    }
}
