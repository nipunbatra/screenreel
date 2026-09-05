import Foundation
import EventCapture
import ProjectModel

/// One-call wiring of a full real recording session: ScreenCaptureKit
/// capture, the durable CaptureSession, and (when permitted) the cursor/click
/// event pipeline. Shared by the app; the CLI keeps its own wiring for
/// flag-level control.
public actor RecordingCoordinator {

    public struct Setup: Sendable {
        public var projectURL: URL
        public var configuration: CaptureConfiguration
        public var captureEvents: Bool
        public var excludeOwnWindows: Bool

        public init(
            projectURL: URL,
            configuration: CaptureConfiguration,
            captureEvents: Bool = true,
            excludeOwnWindows: Bool = true
        ) {
            self.projectURL = projectURL
            self.configuration = configuration
            self.captureEvents = captureEvents
            self.excludeOwnWindows = excludeOwnWindows
        }
    }

    private let setup: Setup
    private let onWarning: @Sendable (String, String) -> Void
    private var session: CaptureSession?
    private var capture: SCKCapture?
    private var camera: CameraCapture?
    private var tap: EventTapSource?
    private var eventContinuation: AsyncStream<EventRecord>.Continuation?
    private var eventPump: Task<Void, Never>?
    public private(set) var eventsActive = false
    /// Keeps App Nap and idle sleep away for the whole session (the app
    /// hides its window while recording, which makes it nap-eligible).
    private var activity: SystemActivity?

    public init(
        setup: Setup,
        onWarning: @escaping @Sendable (String, String) -> Void
    ) {
        self.setup = setup
        self.onWarning = onWarning
    }

    public func start() async throws {
        activity = SystemActivity(.recording, reason: "Screen recording in progress")
        let session = CaptureSession(
            projectURL: setup.projectURL,
            configuration: setup.configuration,
            callbacks: .init(
                onWarning: onWarning,
                onSelfStop: { [weak self] in
                    Task { await self?.closeExternalProducers() }
                }))
        let capture = SCKCapture(
            configuration: setup.configuration,
            clock: session.sessionClock,
            excludeOwnWindows: setup.excludeOwnWindows)
        self.session = session
        self.capture = capture

        var camera: CameraCapture?
        var cameraSettings: VideoWriterSettings?
        defer { self.camera = camera }
        if setup.configuration.cameraEnabled {
            camera = CameraCapture(
                clock: session.sessionClock,
                deviceID: setup.configuration.cameraDeviceID)
            // 0×0: the writer sizes itself from the first real frame. The
            // device's activeFormat is untrustworthy here — the start
            // screen's preview session may have reconfigured it.
            cameraSettings = .camera(
                widthPx: 0, heightPx: 0,
                frameRate: min(30, setup.configuration.nominalFrameRate),
                segmentDurationNs: setup.configuration.segmentDurationNs)
        }

        do {
            try await session.start(
                screen: capture.screenSource(),
                microphone: setup.configuration.microphoneEnabled
                    ? capture.microphoneSource() : nil,
                systemAudio: setup.configuration.systemAudioEnabled
                    ? capture.systemAudioSource() : nil,
                camera: camera,
                cameraSettings: cameraSettings)
        } catch {
            // A partial start must not leave live capture running with no
            // owner (purple indicator forever, files written into a
            // package the caller is about to delete).
            _ = try? await session.stop()
            activity?.end()
            activity = nil
            throw error
        }

        if setup.captureEvents {
            if EventTapSource.hasPermission() || EventTapSource.requestPermission() {
                do {
                    try await startEventCapture(session: session, setup: setup)
                } catch {
                    // Same contract as the media-start catch above: a throw
                    // here (track registration, tap start) must not leave
                    // live capture running with no owner.
                    _ = try? await session.stop()
                    throw error
                }
            } else {
                onWarning(
                    "events.noPermission",
                    "Input Monitoring permission missing; recording without cursor/click events")
            }
        }
    }

    private func startEventCapture(
        session: CaptureSession, setup: Setup
    ) async throws {
        let cursorTrackID = try await session.registerEventTrack(type: .cursorEvents)
        let clickTrackID = try await session.registerEventTrack(type: .clickEvents)
        var trackIDs: [EventChunkKind: UUID] = [
            .cursor: cursorTrackID, .clicks: clickTrackID,
        ]
        if setup.configuration.captureKeystrokesEnabled {
            // Without this registration every keyDown dies at the store's
            // uncaptured-kind guard and the shortcut overlay silently
            // records nothing.
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
        self.eventContinuation = continuation
        let descriptorStore = CursorDescriptorStore(layout: session.projectLayout())
        let clock = session.sessionClock
        let source = EventTapSource(
            descriptorStore: descriptorStore,
            normalizer: { hostNs in clock.normalizeHostNs(hostNs) },
            handler: { record in
                continuation.yield(record)
            },
            // Event pixels must live in the recorded frame's pixel space,
            // which at non-native capture differs from the display's
            // backing scale.
            scaleOverride: setup.configuration.displayScale,
            captureKeyboard: setup.configuration.captureKeystrokesEnabled)
        try source.start()
        self.tap = source
        self.eventsActive = true
        // Tap health rides along in the per-second perf trace.
        await session.setPerfProbe { source.perfCounters() }
        let warn = onWarning
        self.eventPump = Task { [session] in
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
                warn("events.commitFailed", "final chunk: \(error)")
            }
        }
    }

    /// The active camera capture (Sendable), whose `captureSession` a
    /// self-view preview layer can attach to.
    public func activeCamera() -> CameraCapture? {
        camera
    }

    public func pause() async throws {
        try await session?.pause()
    }

    public func resume() async throws {
        try await session?.resume()
    }

    /// Stop the producers the session does not own: the event tap, its
    /// pump, and the activity assertion. Idempotent; the session's disk-full
    /// self-stop calls it before sealing the journal.
    private func closeExternalProducers() async {
        tap?.stop()
        tap = nil
        eventContinuation?.finish()
        eventContinuation = nil
        await eventPump?.value
        eventPump = nil
        activity?.end()
        activity = nil
    }

    public func stop() async throws -> CaptureSession.StopSummary {
        guard let session else {
            throw AksError.invariantViolated("stop() before start()")
        }
        await closeExternalProducers()
        let summary = try await session.stop()
        self.session = nil
        return summary
    }
}
