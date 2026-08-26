import Foundation
import ProjectModel

/// Injectable free-disk-space probe so low-disk behavior is testable
///.
public protocol FreeSpaceProviding: Sendable {
    /// Free bytes on the volume that holds (or will hold) `url`, or nil
    /// when the volume cannot be resolved.
    func freeBytes(for url: URL) -> Int64?
}

/// Reads `volumeAvailableCapacityForImportantUsage`, walking up to the
/// nearest existing ancestor so a not-yet-created project path still
/// resolves the volume it is destined for.
public struct DefaultFreeSpaceProvider: FreeSpaceProviding {
    public init() {}

    public func freeBytes(for url: URL) -> Int64? {
        let fm = FileManager.default
        var probe = url.standardizedFileURL
        var hops = 0
        while !fm.fileExists(atPath: probe.path), hops < 64 {
            let parent = probe.deletingLastPathComponent()
            guard parent.path != probe.path else { break }
            probe = parent
            hops += 1
        }
        return (try? probe.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage
    }
}

/// Orchestrates one recording session end to end, implementing the durable
/// write order of `docs/TECHNICAL_DESIGN.md` §3: project + lock, atomic
/// manifest, journaled track starts, segment commits (journal first, then
/// manifest index), heartbeats, explicit faults, and a finalization sequence
/// that clears `session.lock` only after everything else is durable.
public actor CaptureSession {

    public struct Callbacks: Sendable {
        /// Live operator-facing warnings: (kind, message). The mic-silence
        /// warning arrives within two seconds of samples stopping.
        public var onWarning: @Sendable (String, String) -> Void

        public init(onWarning: @escaping @Sendable (String, String) -> Void = { _, _ in }) {
            self.onWarning = onWarning
        }
    }

    public struct StopSummary: Sendable {
        public let projectURL: URL
        public let durationNs: Int64
        public let videoFrames: Int
        public let droppedVideoFrames: Int
        public let droppedBuffers: Int
        public let micFrames: Int
        public let systemAudioFrames: Int
        public let cameraFrames: Int
        public let validation: ValidationReport
    }

    /// Below this the session self-stops CLEANLY rather than letting the
    /// next media write fail mid-segment. 50 MB.
    static let hardMinimumFreeBytes: Int64 = 50_000_000
    /// Below this the operator is warned once per session. 500 MB.
    static let softMinimumFreeBytes: Int64 = 500_000_000

    private let projectURL: URL
    private let configuration: CaptureConfiguration
    private let callbacks: Callbacks
    private let clock: SessionClock
    private let freeSpace: any FreeSpaceProviding

    private var layout: ProjectLayout?
    private var manifestStore: ManifestStore?
    private var journal: JournalWriter?
    private var sessionID: UUID?

    private var screenSource: (any ScreenFrameSource)?
    private var cameraSource: (any ScreenFrameSource)?
    private var micSource: (any AudioChunkSource)?
    private var systemSource: (any AudioChunkSource)?

    private var videoWriter: VideoSegmentWriter?
    private var cameraWriter: VideoSegmentWriter?
    private var micWriter: AudioSegmentWriter?
    private var systemWriter: AudioSegmentWriter?

    private var consumerTasks: [Task<Void, Never>] = []
    private var heartbeatTask: Task<Void, Never>?

    private var paused = false
    private var stopping = false
    /// Set once a stop finished; repeated stop() calls return it instead of
    /// failing (a disk-full self-stop may have beaten the operator to it).
    private var finishedSummary: StopSummary?
    private var lastMicActivityNs: Int64?
    private var micSilenceReported = false
    private var lastVideoActivityNs: Int64?
    private var videoStallReported = false
    private var lowDiskWarned = false
    private var droppedBufferCount = 0

    public init(
        projectURL: URL,
        configuration: CaptureConfiguration,
        callbacks: Callbacks = Callbacks(),
        freeSpace: any FreeSpaceProviding = DefaultFreeSpaceProvider()
    ) {
        self.projectURL = projectURL
        self.configuration = configuration
        self.callbacks = callbacks
        self.clock = SessionClock()
        self.freeSpace = freeSpace
    }

    public nonisolated var sessionClock: SessionClock { clock }

    // MARK: - Lifecycle

    public func start(
        screen: any ScreenFrameSource,
        microphone: (any AudioChunkSource)?,
        systemAudio: (any AudioChunkSource)?,
        camera: (any ScreenFrameSource)? = nil,
        cameraSettings: VideoWriterSettings? = nil
    ) async throws {
        precondition(layout == nil, "session already started")
        let created = try await ProjectPackage.create(
            at: projectURL,
            clock: clock.anchor,
            capture: try JSONValue(encoding: configuration))
        self.layout = created.layout
        self.manifestStore = created.manifestStore
        self.journal = created.journal
        self.sessionID = created.sessionID
        let layout = created.layout

        // Screen track + writer.
        let screenTrack = TrackDescriptor(
            type: .screen, displayID: configuration.displayID, cursorBaked: false)
        try await registerTrack(screenTrack)
        self.videoWriter = VideoSegmentWriter(
            trackID: screenTrack.id,
            settings: .screen(from: configuration),
            layout: layout,
            onOpen: { [weak self] path, seq in
                try await self?.journalSegmentOpened(trackID: screenTrack.id, path: path, sequence: seq)
            },
            onCommit: { [weak self] descriptor in
                try await self?.commitSegment(descriptor)
            },
            onFault: { [weak self] kind, message in
                await self?.reportFault(kind: kind, message: message)
            })

        // Camera track + writer (same segmented pipeline, raw/camera/).
        if let camera, let cameraSettings {
            let cameraTrack = TrackDescriptor(type: .camera)
            try await registerTrack(cameraTrack)
            self.cameraWriter = VideoSegmentWriter(
                trackID: cameraTrack.id,
                settings: cameraSettings,
                layout: layout,
                onOpen: { [weak self] path, seq in
                    try await self?.journalSegmentOpened(trackID: cameraTrack.id, path: path, sequence: seq)
                },
                onCommit: { [weak self] descriptor in
                    try await self?.commitSegment(descriptor)
                },
                onFault: { [weak self] kind, message in
                    await self?.reportFault(kind: kind, message: message)
                })
            self.cameraSource = camera
        }

        // Microphone track + writer.
        if configuration.microphoneEnabled, let microphone {
            let micTrack = TrackDescriptor(
                type: .microphone,
                deviceUID: configuration.microphoneDeviceUID,
                deviceName: configuration.microphoneDeviceName)
            try await registerTrack(micTrack)
            self.micWriter = AudioSegmentWriter(
                trackID: micTrack.id,
                trackType: .microphone,
                layout: layout,
                sampleRate: configuration.audioSampleRate,
                channels: 1,
                segmentDurationNs: configuration.segmentDurationNs,
                onOpen: { [weak self] path, seq in
                    try await self?.journalSegmentOpened(trackID: micTrack.id, path: path, sequence: seq)
                },
                onCommit: { [weak self] descriptor in
                    try await self?.commitSegment(descriptor)
                },
                onFault: { [weak self] kind, message in
                    await self?.reportFault(kind: kind, message: message)
                })
            self.micSource = microphone
        }

        // System-audio track + writer.
        if configuration.systemAudioEnabled, let systemAudio {
            let systemTrack = TrackDescriptor(type: .systemAudio)
            try await registerTrack(systemTrack)
            self.systemWriter = AudioSegmentWriter(
                trackID: systemTrack.id,
                trackType: .systemAudio,
                layout: layout,
                sampleRate: configuration.audioSampleRate,
                channels: 2,
                segmentDurationNs: configuration.segmentDurationNs,
                onOpen: { [weak self] path, seq in
                    try await self?.journalSegmentOpened(trackID: systemTrack.id, path: path, sequence: seq)
                },
                onCommit: { [weak self] descriptor in
                    try await self?.commitSegment(descriptor)
                },
                onFault: { [weak self] kind, message in
                    await self?.reportFault(kind: kind, message: message)
                })
            self.systemSource = systemAudio
        }

        self.screenSource = screen
        try await wireSources()
        startHeartbeat()
    }

    /// Register an event track (cursor/clicks/keyboard) driven by an external
    /// EventCapture pipeline; returns the track ID for chunk descriptors.
    public func registerEventTrack(type: TrackType) async throws -> UUID {
        precondition(!type.isMedia, "media tracks are registered internally")
        let track = TrackDescriptor(type: type)
        try await registerTrack(track)
        return track.id
    }

    public func pause() async throws {
        guard !paused, let journal else { return }
        paused = true
        pauseStartNs = clock.nowNs()
        try await journal.append(
            type: .pause, timeNs: pauseStartNs ?? 0, payload: JournalPayload.empty())
    }

    private var pauseStartNs: Int64?

    public func resume() async throws {
        guard paused, let journal else { return }
        let now = clock.nowNs()
        try await journal.append(
            type: .resume, timeNs: now, payload: JournalPayload.empty())
        try await journal.append(
            type: .discontinuity, timeNs: now,
            payload: JournalPayload.discontinuity(
                trackID: nil, startNs: pauseStartNs ?? now, endNs: now, reason: "pause"))
        await videoWriter?.markDiscontinuity()
        await cameraWriter?.markDiscontinuity()
        paused = false
    }

    public func stop() async throws -> StopSummary {
        guard let layout, let manifestStore, let journal else {
            throw AksError.invariantViolated("stop() before start()")
        }
        // A finished stop is safely repeatable: the disk-full self-stop may
        // have completed before the operator's own stop arrives.
        if let finishedSummary { return finishedSummary }
        guard !stopping else {
            throw AksError.invariantViolated("stop() called twice")
        }
        stopping = true
        heartbeatTask?.cancel()

        // Stop sources, finish the handoff streams, drain consumers, then
        // close tail segments. A tail-commit failure must not abort the stop
        // sequence: the data survives as an orphan on disk, the fault is
        // journaled, and validation below surfaces it.
        await screenSource?.stop()
        await cameraSource?.stop()
        await micSource?.stop()
        await systemSource?.stop()
        videoContinuation?.finish()
        cameraContinuation?.finish()
        micContinuation?.finish()
        systemContinuation?.finish()
        for task in consumerTasks { await task.value }
        do { try await videoWriter?.finish() } catch {
            await reportFault(kind: "video.finishFailed", message: "\(error)")
        }
        do { try await cameraWriter?.finish() } catch {
            await reportFault(kind: "camera.finishFailed", message: "\(error)")
        }
        do { try await micWriter?.finish() } catch {
            await reportFault(kind: "audio.micFinishFailed", message: "\(error)")
        }
        do { try await systemWriter?.finish() } catch {
            await reportFault(kind: "audio.systemFinishFailed", message: "\(error)")
        }

        let stopTimeNs = clock.nowNs()
        try await journal.append(
            type: .sessionStopped, timeNs: stopTimeNs, payload: JournalPayload.empty())

        // Update duration; final state depends on validation below.
        let manifest = try await manifestStore.save { manifest in
            manifest.state = .ready
        }

        // Post-stop validation: structural checks plus container inspection,
        // checksums skipped for stop latency (the CLI validates deeply).
        let validator = Validator(options: .init(
            verifyChecksums: false, mediaInspector: AVMediaInspector()))
        var report = await validator.validate(projectAt: projectURL)
        // A live lock for *this* process is expected mid-stop, not an error.
        report.issues.removeAll { $0.code == "session.active" }

        let healthy = !report.issues.contains { $0.severity == .error }
        if !healthy {
            _ = try await manifestStore.save { manifest in
                manifest.state = .recoverable
            }
            for issue in report.issues where issue.severity == .error {
                callbacks.onWarning(issue.code, issue.message)
            }
        }
        try await journal.append(
            type: .validationCompleted,
            timeNs: clock.nowNs(),
            payload: JSONValue(encoding: [
                "healthy": .bool(healthy),
                "errors": .integer(Int64(report.issues.filter { $0.severity == .error }.count)),
                "warnings": .integer(Int64(report.issues.filter { $0.severity == .warning }.count)),
            ] as [String: JSONValue]))
        try await journal.append(
            type: .sessionFinalized, timeNs: clock.nowNs(), payload: JournalPayload.empty())

        // Only now is the incomplete-session marker cleared.
        try? FileManager.default.removeItem(at: layout.sessionLockURL)
        try await manifestStore.clearHistoryAfterCleanClose()
        try AtomicFile.syncDirectory(layout.root)

        let summary = StopSummary(
            projectURL: projectURL,
            durationNs: manifest.durationNs ?? 0,
            videoFrames: await videoWriter?.totalFrames ?? 0,
            droppedVideoFrames: await videoWriter?.droppedFrames ?? 0,
            droppedBuffers: droppedBufferCount,
            micFrames: await micWriter?.totalFrames ?? 0,
            systemAudioFrames: await systemWriter?.totalFrames ?? 0,
            cameraFrames: await cameraWriter?.totalFrames ?? 0,
            validation: report)
        finishedSummary = summary
        return summary
    }

    /// Non-nil once a stop (operator- or disk-initiated) has fully
    /// finalized the project.
    func finishedStopSummary() -> StopSummary? { finishedSummary }

    // MARK: - Commit plumbing (shared with EventCapture via the CLI wiring)

    public func commitEventChunk(_ chunk: EventChunkDescriptor) async throws {
        guard let journal, let manifestStore else { return }
        // The journal assigns commitSequence inside its own actor so the
        // payload always matches its record even when commits interleave.
        let record = try await journal.append(
            type: .eventChunkCommitted, timeNs: chunk.endNs
        ) { sequence in
            var chunk = chunk
            chunk.commitSequence = sequence
            return try JournalPayload.eventChunkCommitted(chunk)
        }
        let committed = try record.payload.decoded(as: EventChunkDescriptor.self)
        _ = try await manifestStore.save { manifest in
            manifest.appendEventChunk(committed)
        }
    }

    /// Surface a fault from an externally-wired pipeline (e.g. the event
    /// chunk store driven by the CLI): warns the operator and journals it.
    public func noteExternalFault(kind: String, message: String) async {
        await reportFault(kind: kind, message: message)
    }

    public nonisolated func projectLayout() -> ProjectLayout {
        ProjectLayout(root: projectURL)
    }

    public func currentTimeNs() -> Int64 { clock.nowNs() }
    public func isPaused() -> Bool { paused }

    // MARK: - Internals

    private func registerTrack(_ track: TrackDescriptor) async throws {
        guard let journal, let manifestStore else { return }
        try await journal.append(
            type: .trackStarted,
            timeNs: clock.nowNs(),
            payload: JournalPayload.trackStarted(track))
        _ = try await manifestStore.save { manifest in
            manifest.tracks.append(track)
        }
    }

    private func journalSegmentOpened(trackID: UUID, path: String, sequence: Int) async throws {
        guard let journal else { return }
        try await journal.append(
            type: .segmentOpened,
            timeNs: clock.nowNs(),
            payload: JournalPayload.segmentOpened(trackID: trackID, path: path, sequenceInTrack: sequence),
            durable: false)
    }

    private func commitSegment(_ descriptor: SegmentDescriptor) async throws {
        guard let journal, let manifestStore else { return }
        // The journal assigns commitSequence inside its own actor so the
        // payload always matches its record even when commits interleave.
        let record = try await journal.append(
            type: .segmentCommitted, timeNs: descriptor.normalizedEndNs
        ) { sequence in
            var descriptor = descriptor
            descriptor.commitSequence = sequence
            return try JournalPayload.segmentCommitted(descriptor)
        }
        let committed = try record.payload.decoded(as: SegmentDescriptor.self)
        _ = try await manifestStore.save { manifest in
            manifest.appendSegment(committed)
        }
    }

    private func reportFault(kind: String, message: String) async {
        callbacks.onWarning(kind, message)
        guard let journal else { return }
        _ = try? await journal.append(
            type: .fault,
            timeNs: clock.nowNs(),
            payload: (try? JournalPayload.fault(kind: kind, message: message)) ?? .object([:]))
    }

    private func noteVideoActivity(_ ptsNs: Int64) {
        lastVideoActivityNs = clock.nowNs()
        videoStallReported = false
    }

    private func noteMicActivity(_ ptsNs: Int64) {
        lastMicActivityNs = ptsNs
        micSilenceReported = false
    }

    private func noteDroppedBuffer(stream: String) async {
        droppedBufferCount += 1
        if droppedBufferCount == 1 || droppedBufferCount % 100 == 0 {
            await reportFault(
                kind: "capture.buffersDropped",
                message: "\(stream) buffer queue overflow; \(droppedBufferCount) dropped so far")
        }
    }

    private func wireSources() async throws {
        // Video pipeline: bounded handoff from the capture callback to the
        // writer actor. The capture-side yield never blocks; overflow is
        // counted and reported, never hidden.
        // 6, not more: each buffered frame pins one of SCK's 8 pool
        // surfaces on the zero-copy path; overflow is a counted drop,
        // pool starvation is silent.
        let (videoStream, videoContinuation) = AsyncStream.makeStream(
            of: VideoFrame.self, bufferingPolicy: .bufferingOldest(6))
        self.videoContinuation = videoContinuation
        try await screenSource?.start { [weak self] frame in
            guard let self else { return }
            let result = videoContinuation.yield(frame)
            if case .dropped = result {
                Task { await self.noteDroppedBuffer(stream: "video") }
            }
        }
        let videoWriter = self.videoWriter
        consumerTasks.append(Task { [weak self] in
            for await frame in videoStream {
                if await self?.isPaused() == true { continue }
                await self?.noteVideoActivity(frame.ptsNs)
                do {
                    try await videoWriter?.append(frame)
                } catch {
                    await self?.reportFault(kind: "video.writeFailed", message: "\(error)")
                    break
                }
            }
        })

        if let cameraSource, let cameraWriter {
            let (cameraStream, cameraContinuation) = AsyncStream.makeStream(
                of: VideoFrame.self, bufferingPolicy: .bufferingOldest(16))
            self.cameraContinuation = cameraContinuation
            try await cameraSource.start { [weak self] frame in
                guard let self else { return }
                let result = cameraContinuation.yield(frame)
                if case .dropped = result {
                    Task { await self.noteDroppedBuffer(stream: "camera") }
                }
            }
            consumerTasks.append(Task { [weak self] in
                for await frame in cameraStream {
                    if await self?.isPaused() == true { continue }
                    do {
                        try await cameraWriter.append(frame)
                    } catch {
                        await self?.reportFault(kind: "camera.writeFailed", message: "\(error)")
                        break
                    }
                }
            })
        }

        if let micSource, let micWriter {
            let (micStream, micContinuation) = AsyncStream.makeStream(
                of: AudioChunk.self, bufferingPolicy: .bufferingOldest(64))
            self.micContinuation = micContinuation
            try await micSource.start { [weak self] chunk in
                guard let self else { return }
                let result = micContinuation.yield(chunk)
                if case .dropped = result {
                    Task { await self.noteDroppedBuffer(stream: "microphone") }
                }
            }
            consumerTasks.append(Task { [weak self] in
                for await chunk in micStream {
                    await self?.noteMicActivity(chunk.ptsNs)
                    if await self?.isPaused() == true { continue }
                    do {
                        try await micWriter.append(chunk)
                    } catch {
                        await self?.reportFault(kind: "audio.micWriteFailed", message: "\(error)")
                        break
                    }
                }
            })
        }

        if let systemSource, let systemWriter {
            let (systemStream, systemContinuation) = AsyncStream.makeStream(
                of: AudioChunk.self, bufferingPolicy: .bufferingOldest(64))
            self.systemContinuation = systemContinuation
            try await systemSource.start { [weak self] chunk in
                guard let self else { return }
                let result = systemContinuation.yield(chunk)
                if case .dropped = result {
                    Task { await self.noteDroppedBuffer(stream: "systemAudio") }
                }
            }
            consumerTasks.append(Task { [weak self] in
                for await chunk in systemStream {
                    if await self?.isPaused() == true { continue }
                    do {
                        try await systemWriter.append(chunk)
                    } catch {
                        await self?.reportFault(kind: "audio.systemWriteFailed", message: "\(error)")
                        break
                    }
                }
            })
        }

    }

    private var videoContinuation: AsyncStream<VideoFrame>.Continuation?
    private var cameraContinuation: AsyncStream<VideoFrame>.Continuation?
    private var micContinuation: AsyncStream<AudioChunk>.Continuation?
    private var systemContinuation: AsyncStream<AudioChunk>.Continuation?

    private func startHeartbeat() {
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                await self?.heartbeat()
            }
        }
    }

    private func heartbeat() async {
        guard !stopping, let layout, let journal, let sessionID else { return }

        // Free-space guard: exhausting the
        // volume must end the session CLEANLY — writers finished, segments
        // committed, manifest finalized — never by letting the next media
        // write fail mid-segment. Soft threshold warns once; hard threshold
        // journals `disk.full` and self-stops through the normal sequence.
        if let free = freeSpace.freeBytes(for: layout.root) {
            if free < Self.hardMinimumFreeBytes {
                await reportFault(
                    kind: "disk.full",
                    message: "only \(free) bytes free on the recording volume; "
                        + "stopping cleanly to keep everything captured so far readable")
                do {
                    _ = try await stop()
                } catch {
                    callbacks.onWarning(
                        "disk.full", "clean stop after disk exhaustion failed: \(error)")
                }
                return
            }
            if free < Self.softMinimumFreeBytes, !lowDiskWarned {
                lowDiskWarned = true
                await reportFault(
                    kind: "disk.low",
                    message: "under \(Self.softMinimumFreeBytes / 1_000_000) MB free on the "
                        + "recording volume; the session will stop itself cleanly below "
                        + "\(Self.hardMinimumFreeBytes / 1_000_000) MB")
            }
            guard !stopping else { return }
        }

        let lastCommitted = await journal.lastCommittedSequence
        // Re-check after the suspension: stop() may have removed the lock
        // while we awaited the journal, and rewriting it would make a cleanly
        // finalized project look crashed. No suspension below this point.
        guard !stopping else { return }
        let lock = SessionLock(sessionID: sessionID, lastCommittedSequence: lastCommitted)
        try? lock.write(to: layout.sessionLockURL, durable: false)

        // Mic-absence gate: warn within two seconds and journal the fault
        // (`docs/AUDIO_PIPELINE.md` §2).
        if configuration.microphoneEnabled, micWriter != nil, !paused {
            let now = clock.nowNs()
            let last = lastMicActivityNs ?? 0
            if now - last > 2_000_000_000, !micSilenceReported {
                micSilenceReported = true
                await reportFault(
                    kind: "audio.micSilent",
                    message: "no microphone samples for over 2 seconds; screen capture continues")
            }
        }

        // Video-stall visibility: surface-pool starvation stops delivery
        // with no callback and no counted drop. A static screen also sends
        // nothing, so this cannot distinguish the two — it exists so a
        // stalled capture is at least VISIBLE in warnings and the journal.
        if videoWriter != nil, !paused {
            let now = clock.nowNs()
            if let last = lastVideoActivityNs,
                now - last > 10_000_000_000, !videoStallReported
            {
                videoStallReported = true
                callbacks.onWarning(
                    "video.quiet",
                    "no screen frames for 10 s — normal for a static screen; if the screen IS changing, the capture may be stalled")
            }
        }
    }
}
