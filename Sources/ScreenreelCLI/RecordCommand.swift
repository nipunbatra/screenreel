import ArgumentParser
import CaptureCore
import Dispatch
import EventCapture
import Foundation
import ProjectModel

struct Record: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Record a segmented, crash-recoverable capture session.",
        discussion: """
            --synthetic drives the full durable-write pipeline from
            deterministic generated sources (no permissions needed); it is what
            the integration and forced-quit tests use. Real capture uses
            ScreenCaptureKit and needs Screen Recording permission for the
            invoking terminal; cursor/click events additionally need Input
            Monitoring permission.
            """)

    @Option(help: "Project package to create (default: './Recording <timestamp>.screenreel').")
    var output: String?

    @Flag(help: "Use deterministic synthetic sources instead of real capture.")
    var synthetic = false

    @Option(help: "Recording duration in seconds (default: synthetic 10 s; real capture runs until Ctrl-C).")
    var duration: Double?

    @Option(help: "Capture width in pixels (synthetic default 1280; real default: display size).")
    var width: Int?

    @Option(help: "Capture height in pixels (synthetic default 720; real default: display size).")
    var height: Int?

    @Option(help: "Nominal frame rate.")
    var fps: Double = 30

    @Option(help: "Display ID to record (see 'screenreel env').")
    var display: Int?

    @Flag(help: "Also record keystrokes for the shortcut overlay (OFF by default: keystrokes can include passwords).")
    var keystrokes = false

    @Flag(inversion: .prefixedNo, help: "Capture microphone audio.")
    var mic = true

    @Flag(help: "Capture system audio.")
    var systemAudio = false

    @Flag(inversion: .prefixedNo, help: "Capture cursor/click events.")
    var events = true

    @Option(help: "Raw video codec: hevc or h264.")
    var codec: String = "hevc"

    @Option(help: "Segment duration in seconds (2-5).")
    var segmentSeconds: Double = 4

    @Option(help: "Synthetic pacing: 1.0 = real time, 0 = as fast as possible.")
    var pace: Double = 0

    func run() async throws {
        let stamp = RFC3339.now().replacingOccurrences(of: ":", with: "-").prefix(19)
        let projectPath = output ?? "./Recording \(stamp).screenreel"
        let url = projectURL(from: projectPath)
        guard codec == "hevc" || codec == "h264" else {
            throw ValidationError("--codec must be hevc or h264")
        }

        if synthetic {
            let durationNs = Int64((duration ?? 10) * 1_000_000_000)
            try await recordSynthetic(url: url, durationNs: durationNs)
        } else {
            // Real capture defaults to open-ended: record until Ctrl-C
            // (12 h is the safety ceiling, far beyond any lecture).
            let durationNs = Int64((duration ?? 43_200) * 1_000_000_000)
            try await recordReal(url: url, durationNs: durationNs)
        }
    }

    // MARK: - Synthetic

    private func recordSynthetic(url: URL, durationNs: Int64) async throws {
        let configuration = CaptureConfiguration(
            widthPx: width ?? 1280,
            heightPx: height ?? 720,
            nominalFrameRate: fps,
            videoCodec: codec == "h264" ? .h264 : .hevc,
            displayID: display ?? 1,
            microphoneEnabled: mic,
            microphoneDeviceName: mic ? "Synthetic Microphone" : nil,
            systemAudioEnabled: systemAudio,
            segmentDurationSeconds: segmentSeconds)
        // The event tap and its pump are created after the session starts;
        // the disk-full self-stop must be able to close them first, so they
        // live in a box the callback can reach.
        let producers = ExternalProducers()
        let session = CaptureSession(
            projectURL: url, configuration: configuration,
            callbacks: .init(
                onWarning: { kind, message in
                    FileHandle.standardError.write(Data("WARNING [\(kind)] \(message)\n".utf8))
                },
                onSelfStop: { producers.close() }))

        let screen = SyntheticScreenSource(
            width: configuration.widthPx, height: configuration.heightPx,
            frameRate: fps, durationNs: durationNs, pace: pace)
        let micSource = mic
            ? SyntheticAudioSource(channels: 1, durationNs: durationNs, pace: pace)
            : nil
        let systemSource = systemAudio
            ? SyntheticAudioSource(channels: 2, durationNs: durationNs, pace: pace, frequency: 220)
            : nil

        print("Recording (synthetic) → \(url.path)")
        try await session.start(screen: screen, microphone: micSource, systemAudio: systemSource)

        var eventPump: Task<Void, Never>?
        var eventSource: SyntheticEventSource?
        if events {
            let cursorTrackID = try await session.registerEventTrack(type: .cursorEvents)
            let clickTrackID = try await session.registerEventTrack(type: .clickEvents)
            var trackIDs: [EventChunkKind: UUID] = [
                .cursor: cursorTrackID, .clicks: clickTrackID,
            ]
            if keystrokes {
                trackIDs[.keyboard] = try await session.registerEventTrack(
                    type: .keyboardEvents)
            }
            let store = EventChunkStore(
                layout: session.projectLayout(),
                trackIDs: trackIDs,
                onCommit: { [session] chunk in
                    try await session.commitEventChunk(chunk)
                })
            let (stream, continuation) = AsyncStream.makeStream(of: EventRecord.self)
            let source = SyntheticEventSource(
                durationNs: durationNs,
                widthPx: Double(configuration.widthPx),
                heightPx: Double(configuration.heightPx),
                pace: pace,
                emitKeystrokes: keystrokes)
            source.start { record in
                continuation.yield(record)
            }
            eventSource = source
            eventPump = Task { [session] in
                for await record in stream {
                    do {
                        try await store.append(record)
                    } catch {
                        await session.noteExternalFault(
                            kind: "events.commitFailed", message: "\(error)")
                    }
                }
                do {
                    try await store.finish()
                } catch {
                    await session.noteExternalFault(
                        kind: "events.commitFailed", message: "final chunk: \(error)")
                }
            }
            Task {
                await source.waitUntilFinished()
                continuation.finish()
            }
        }

        await screen.waitUntilFinished()
        if let micSource { await micSource.waitUntilFinished() }
        if let systemSource { await systemSource.waitUntilFinished() }
        if let eventSource { await eventSource.waitUntilFinished() }
        await eventPump?.value

        let summary = try await session.stop()
        printSummary(summary)
    }

    // MARK: - Real capture

    private func recordReal(url: URL, durationNs: Int64) async throws {
        let displays = try await SCKCapture.availableDisplays()
        guard let target = displays.first(where: { display in
            self.display.map { Int(display.displayID) == $0 } ?? true
        }) else {
            throw CLIError.failed("No capturable display. Grant Screen Recording permission to this terminal in System Settings → Privacy & Security → Screen Recording, then retry.")
        }

        let captureWidth = width ?? target.widthPx
        let configuration = CaptureConfiguration(
            widthPx: captureWidth,
            heightPx: height ?? target.heightPx,
            nominalFrameRate: fps,
            videoCodec: codec == "h264" ? .h264 : .hevc,
            displayID: Int(target.displayID),
            // Pixels-per-point of the capture (not of the panel): event
            // pixels must land in recorded-frame space.
            displayScale: Double(captureWidth) / Double(max(1, target.widthPoints)),
            microphoneEnabled: mic,
            systemAudioEnabled: systemAudio,
            segmentDurationSeconds: segmentSeconds)
        // The event tap and its pump are created after the session starts;
        // the disk-full self-stop must be able to close them first, so they
        // live in a box the callback can reach.
        let producers = ExternalProducers()
        let session = CaptureSession(
            projectURL: url, configuration: configuration,
            callbacks: .init(
                onWarning: { kind, message in
                    FileHandle.standardError.write(Data("WARNING [\(kind)] \(message)\n".utf8))
                },
                onSelfStop: { producers.close() }))

        // Disk preflight: the raw session writes video + PCM audio; running
        // out of space mid-lecture is the exact failure class this tool
        // exists to avoid, so surface the math up front.
        let videoBytesPerHour = Double(configuration.widthPx * configuration.heightPx)
            * configuration.nominalFrameRate * configuration.bitsPerPixelPerFrame / 8 * 3600
        let audioBytesPerHour = configuration.audioSampleRate * 4 * 3600
            * Double((mic ? 1 : 0) + (systemAudio ? 2 : 0))
        let bytesPerHour = Int64(videoBytesPerHour + audioBytesPerHour)
        let destinationDir = url.deletingLastPathComponent()
        let freeBytes = (try? destinationDir.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage ?? 0
        let gbPerHour = Double(bytesPerHour) / 1_073_741_824
        let freeGB = Double(freeBytes) / 1_073_741_824
        print(String(
            format: "Disk: %.1f GB free, recording uses ~%.1f GB/hour (≈ %.1f hours of headroom).",
            freeGB, gbPerHour, freeGB / max(gbPerHour, 0.001)))
        if freeBytes < bytesPerHour {
            FileHandle.standardError.write(Data(
                "WARNING [disk.low] less than one hour of recording headroom on this volume\n".utf8))
        }

        let capture = SCKCapture(configuration: configuration, clock: session.sessionClock)
        print("Recording display \(target.displayID) at \(configuration.widthPx)x\(configuration.heightPx)@\(Int(fps)) → \(url.path)")
        print("Press Ctrl-C to stop.")
        try await session.start(
            screen: capture.screenSource(),
            microphone: mic ? capture.microphoneSource() : nil,
            systemAudio: systemAudio ? capture.systemAudioSource() : nil)

        // Cursor/click events via a listen-only event tap.
        var tap: EventTapSource?
        var eventPump: Task<Void, Never>?
        var eventContinuation: AsyncStream<EventRecord>.Continuation?
        if events {
            if EventTapSource.hasPermission() || EventTapSource.requestPermission() {
                let cursorTrackID = try await session.registerEventTrack(type: .cursorEvents)
                let clickTrackID = try await session.registerEventTrack(type: .clickEvents)
                var trackIDs: [EventChunkKind: UUID] = [
                    .cursor: cursorTrackID, .clicks: clickTrackID,
                ]
                if keystrokes {
                    trackIDs[.keyboard] = try await session.registerEventTrack(
                        type: .keyboardEvents)
                }
                let store = EventChunkStore(
                    layout: session.projectLayout(),
                    trackIDs: trackIDs,
                    onCommit: { [session] chunk in
                        try await session.commitEventChunk(chunk)
                    })
                let (stream, continuation) = AsyncStream.makeStream(of: EventRecord.self)
                eventContinuation = continuation
                let descriptorStore = CursorDescriptorStore(layout: session.projectLayout())
                let clock = session.sessionClock
                let source = EventTapSource(
                    descriptorStore: descriptorStore,
                    normalizer: { hostNs in clock.normalizeHostNs(hostNs) },
                    handler: { record in
                        continuation.yield(record)
                    },
                    scaleOverride: configuration.displayScale,
                    captureKeyboard: keystrokes)
                try source.start()
                tap = source
                producers.set(tap: source, continuation: continuation)
                await session.setPerfProbe { source.perfCounters() }
                eventPump = Task { [session] in
                    for await record in stream {
                        do {
                            try await store.append(record)
                        } catch {
                            await session.noteExternalFault(
                                kind: "events.commitFailed", message: "\(error)")
                        }
                    }
                    do {
                        try await store.finish()
                    } catch {
                        await session.noteExternalFault(
                            kind: "events.commitFailed", message: "final chunk: \(error)")
                    }
                }
            } else {
                FileHandle.standardError.write(Data(
                    "WARNING [events.noPermission] Input Monitoring permission missing; recording without cursor/click events.\n".utf8))
            }
        }

        await Self.sleepUntilDeadlineOrInterrupt(durationNs: durationNs)

        tap?.stop()
        eventContinuation?.finish()
        await eventPump?.value
        let summary = try await session.stop()
        printSummary(summary)
    }

    // Held so cancel() can run after the wait completes.
    private nonisolated(unsafe) static var interruptSource: DispatchSourceSignal?

    /// Wait for the duration to elapse or SIGINT, whichever comes first.
    private static func sleepUntilDeadlineOrInterrupt(durationNs: Int64) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let resumed = OSAllocatedUnfairLockBox()
            signal(SIGINT, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
            interruptSource = source
            source.setEventHandler {
                if resumed.claim() { continuation.resume() }
            }
            source.resume()
            DispatchQueue.global().asyncAfter(
                deadline: .now() + .nanoseconds(Int(durationNs))
            ) {
                if resumed.claim() { continuation.resume() }
            }
        }
        interruptSource?.cancel()
        interruptSource = nil
    }

    private func printSummary(_ summary: CaptureSession.StopSummary) {
        print("Stopped. Project: \(summary.projectURL.path)")
        print("Duration: \(Output.duration(ns: summary.durationNs))")
        print("Video frames: \(summary.videoFrames) (dropped \(summary.droppedVideoFrames) frames, \(summary.droppedBuffers) buffers)")
        if summary.micFrames > 0 {
            print("Microphone samples: \(summary.micFrames)")
        }
        if summary.systemAudioFrames > 0 {
            print("System audio samples: \(summary.systemAudioFrames)")
        }
        if let perf = summary.perf {
            print("Performance: \(perf.headline)")
            for concern in perf.concerns {
                print("  PERF \(concern)")
            }
        }
        let state = summary.validation.isHealthy ? "healthy" : "NEEDS ATTENTION"
        print("Validation: \(state) (\(summary.validation.issues.count) issue(s))")
        for issue in summary.validation.issues where issue.severity != .info {
            print("  \(issue.severity.rawValue.uppercased()) [\(issue.code)] \(issue.message)")
        }
    }
}

/// Holds the producers the session does not own so a session-initiated
/// stop (disk exhausted) can close them before the journal is sealed.
final class ExternalProducers: @unchecked Sendable {
    private let lock = NSLock()
    private var tap: EventTapSource?
    private var continuation: AsyncStream<EventRecord>.Continuation?

    func set(tap: EventTapSource, continuation: AsyncStream<EventRecord>.Continuation) {
        lock.lock()
        self.tap = tap
        self.continuation = continuation
        lock.unlock()
    }

    func close() {
        lock.lock()
        let tap = self.tap
        let continuation = self.continuation
        self.tap = nil
        self.continuation = nil
        lock.unlock()
        tap?.stop()
        continuation?.finish()
    }
}

/// Tiny once-guard for racing completion paths.
final class OSAllocatedUnfairLockBox: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false
    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if claimed { return false }
        claimed = true
        return true
    }
}
