import AVFoundation
import CoreImage
import Foundation
import Observation
import Captions
import PreviewEngine
import ProjectModel
import TimelineCore

/// Wraps a `CGImage` for transfer out of the render actor; the image is
/// created there and never mutated afterward.
struct RenderedFrame: @unchecked Sendable {
    let image: CGImage
    let timeNs: Int64
}

/// Owns the `ProjectComposition` off the main thread. All evaluation and
/// edit mutation funnels through this actor; the UI only ever sees rendered
/// frames and value-type edit documents.
actor CompositionBox {
    private let composition: ProjectComposition
    private let context = CIContext()

    init(projectURL: URL) throws {
        // Preview decodes at proxy resolution (fast 4K scrubbing); export
        // builds its own full-resolution composition. Geometry is identical.
        // 1440 keeps text legible on 5K panels while still quartering the
        // decode work of a 2880-tall source.
        composition = try ProjectComposition(
            projectURL: projectURL, previewDecodeMaxHeight: 1440)
    }

    var durationNs: Int64 { composition.durationNs }
    var outputDurationNs: Int64 { composition.outputDurationNs }
    var sourceSize: SIMD2<Double> { composition.sourceSize }
    var edits: EditDocument { composition.edits }
    var micSegments: [SegmentDescriptor] { composition.micSegments }
    var systemSegments: [SegmentDescriptor] { composition.systemSegments }
    var hasKeystrokes: Bool { composition.hasKeystrokes }
    var hasCamera: Bool { !composition.cameraSegments.isEmpty }
    var layout: ProjectLayout { composition.layout }
    var projectURL: URL { composition.projectURL }

    func setOutputSize(_ size: SIMD2<Double>) {
        composition.setOutputSize(size)
    }

    func renderedFrame(at timeNs: Int64) async -> RenderedFrame? {
        guard let ci = try? await composition.frame(atOutput: timeNs) else { return nil }
        guard let cg = context.createCGImage(ci, from: ci.extent) else { return nil }
        return RenderedFrame(image: cg, timeNs: timeNs)
    }

    func updateEdits(_ mutate: @Sendable (inout EditDocument) -> Void) throws -> EditDocument {
        try composition.updateEdits(mutate)
        return composition.edits
    }

    func regenerateZooms() throws -> EditDocument {
        try composition.regenerateZooms()
        return composition.edits
    }

    func sourceFocal(atCanvasFraction fraction: CGPoint, outputNs: Int64) -> SIMD2<Double> {
        let size = composition.canvasSize
        return composition.sourceFocal(
            atCanvasPoint: SIMD2(fraction.x * size.x, fraction.y * size.y),
            outputNs: outputNs)
    }

    /// Click times + cursor samples for dead-stretch detection.
    func activityDigest() -> (clicks: [Int64], cursor: [(Int64, Double, Double)]) {
        let timeline = composition.motionTimeline
        return (
            timeline.downs.map(\.timeNs),
            timeline.moves.map { ($0.timeNs, $0.position.x, $0.position.y) })
    }
}

/// Playback/scrub state for the editor. Frames render through the same
/// composition the exporter uses; audio preview plays the raw mic track
/// scheduled on an AVAudioEngine.
@Observable
@MainActor
final class PreviewPlayer {
    let projectURL: URL
    let box: CompositionBox
    /// OUTPUT duration (after cuts) — everything UI-facing uses this.
    private(set) var durationNs: Int64 = 0
    /// Raw source duration (for clip math and source-anchored overlays).
    private(set) var sourceDurationNs: Int64 = 0
    private(set) var sourceSize = SIMD2<Double>(1, 1)
    private(set) var edits = EditDocument()
    private(set) var currentFrame: CGImage?
    /// Shown instantly while the first real frame decodes (cached browser
    /// thumbnail) — an empty spinner canvas reads as "broken".
    private(set) var placeholder: CGImage?
    private(set) var isPlaying = false
    var timeNs: Int64 = 0
    var exportState: ExportState = .idle
    var loadError: String?
    /// Timeline/inspector selection sync.
    var selectedZoomID: UUID?
    /// Whole-document undo/redo (every edit goes through updateEdits).
    private var history = EditHistory()
    private(set) var canUndo = false
    private(set) var canRedo = false
    /// Whether the project has a recorded camera track.
    private(set) var hasCamera = false
    /// Mic peak buckets for the timeline waveform (output timeline).
    private(set) var waveform: [Float] = []
    private var sourceWaveform: [Float] = []

    /// Map source-domain peaks onto the (possibly cut) output timeline.
    private func remapWaveform() {
        guard !sourceWaveform.isEmpty, sourceDurationNs > 0 else {
            waveform = sourceWaveform
            return
        }
        let timeline = ClipTimeline(
            clips: edits.clips, sourceDurationNs: sourceDurationNs)
        guard timeline.outputDurationNs > 0 else {
            waveform = []
            return
        }
        let count = sourceWaveform.count
        waveform = (0..<count).map { bucket in
            let outputNs = Int64(
                Double(timeline.outputDurationNs) * (Double(bucket) + 0.5)
                    / Double(count))
            let sourceNs = timeline.sourceTime(forOutput: outputNs)
            let index = min(
                count - 1,
                Int(Double(sourceNs) / Double(sourceDurationNs) * Double(count)))
            return sourceWaveform[max(0, index)]
        }
    }

    enum ExportState: Equatable {
        case idle
        case running(stage: String, fraction: Double)
        case done(URL)
        case failed(String)
    }

    private var playbackTask: Task<Void, Never>?
    private var renderInFlight = false
    private var pendingRenderNs: Int64?
    private let audio = AudioPreview()
    /// Transport commands chained FIFO: unstructured Tasks reach the audio
    /// actor in nondeterministic order, and a stale stop landing after a
    /// play left video running silent.
    private var audioCommandChain: Task<Void, Never>?

    private func enqueueAudio(_ command: @escaping @Sendable (AudioPreview) async -> Void) {
        let previous = audioCommandChain
        let audio = self.audio
        audioCommandChain = Task {
            await previous?.value
            await command(audio)
        }
    }

    init(projectURL: URL) throws {
        self.projectURL = projectURL
        self.box = try CompositionBox(projectURL: projectURL)
        Task { [weak self] in
            let image = await ProjectThumbnailer.thumbnail(for: projectURL)
            if let self, self.currentFrame == nil { self.placeholder = image }
        }
        Task {
            self.sourceDurationNs = await box.durationNs
            self.durationNs = await box.outputDurationNs
            self.sourceSize = await box.sourceSize
            self.edits = await box.edits
            self.hasCamera = await box.hasCamera
            let micSegments = await box.micSegments
            let layout = await box.layout
            self.hasMicAudio = !micSegments.isEmpty
            self.hasKeystrokes = await box.hasKeystrokes
            let systemSegments = await box.systemSegments
            await audio.prepare(
                micSegments: micSegments, systemSegments: systemSegments,
                layout: layout)
            if let saved = try? CaptionStore.load(from: layout), !saved.isEmpty {
                self.captions = saved
                self.captionStatus =
                    "\(saved.count) caption cue\(saved.count == 1 ? "" : "s") loaded."
            }
            // Preview at reduced resolution for responsiveness; geometry is
            // identical to export by construction.
            await box.setOutputSize(self.previewOutputSize())
            self.requestFrame(at: 0)

            // Waveform computation is CPU work: off the main actor.
            let waveformSegments = micSegments
            let waveformLayout = layout
            // peaks() buckets by SOURCE time — the output duration here
            // dropped/misplaced audio whenever saved clips shortened output.
            let waveformDuration = self.sourceDurationNs
            let peaks = await Task.detached(priority: .utility) {
                AudioWaveform.peaks(
                    segments: waveformSegments,
                    layout: waveformLayout,
                    durationNs: waveformDuration)
            }.value
            self.sourceWaveform = peaks
            self.remapWaveform()
        }
    }

    /// The on-screen preview surface in pixels; rendering at less than
    /// this is what made the editor look blurry on Retina panels.
    private var surfacePx: SIMD2<Double>?

    /// Called by the preview view whenever its layout changes, so frames
    /// render at the surface's real pixel size (capped at the source).
    func setPreviewSurface(pointSize: CGSize, displayScale: Double) {
        let px = SIMD2(
            pointSize.width * max(1, displayScale),
            pointSize.height * max(1, displayScale))
        guard px.x > 50, px.y > 50 else { return }
        if let current = surfacePx,
            abs(current.x - px.x) < 24, abs(current.y - px.y) < 24
        {
            return
        }
        surfacePx = px
        enqueueOutputSize(previewOutputSize(halved: isPlaying), renderAt: timeNs)
    }

    /// Preview canvas size honoring the edit document's aspect ratio,
    /// fitted to the actual surface and never above source resolution.
    /// `halved` renders playback at half linear resolution (quarter the
    /// pixels) — parked frames always use full quality.
    private func previewOutputSize(halved: Bool = false) -> SIMD2<Double> {
        let aspect = edits.style.canvasAspect
            ?? (sourceSize.x / max(sourceSize.y, 1))
        let surface = surfacePx ?? SIMD2(1280, 800)
        var height = min(surface.y, surface.x / aspect)
        height = max(180, min(height, sourceSize.y))
        if halved { height = max(180, height / 2) }
        return SIMD2(max(2, (height * aspect).rounded()), height.rounded())
    }

    func shutdown() {
        playbackTask?.cancel()
        enqueueAudio { await $0.stop() }
    }

    /// Output-size changes are FIFO-chained like audio commands: a pause's
    /// full-quality restore can never be overtaken by a stale half-res
    /// request from the play that preceded it.
    private var qualityChain: Task<Void, Never>?
    private func enqueueOutputSize(_ size: SIMD2<Double>, renderAt: Int64? = nil) {
        let previous = qualityChain
        qualityChain = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            await self.box.setOutputSize(size)
            if let renderAt { self.requestFrame(at: renderAt) }
        }
    }

    // MARK: - Transport

    func togglePlay() {
        isPlaying ? pause() : play()
    }

    func play() {
        guard !isPlaying else { return }
        if timeNs >= durationNs { timeNs = 0 }
        isPlaying = true
        let startNs = timeNs
        let anchor = DispatchTime.now().uptimeNanoseconds
        // Preview audio follows the SAME cut/speed policy as export: kept
        // 1× spans play their source audio, cuts skip, sped spans are
        // silent. Feeding raw source audio here made preview disagree with
        // export the moment a clip was cut.
        let plan = PreviewAudioPlan.entries(
            timeline: effectiveClipTimeline, fromOutput: startNs)
        enqueueAudio { await $0.play(plan: plan) }
        // Playback renders at half resolution (quarter the pixels); the
        // parked frame after pause returns to full quality via the chain.
        enqueueOutputSize(previewOutputSize(halved: true))
        playbackTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.isPlaying else { return }
                let elapsed = Int64(DispatchTime.now().uptimeNanoseconds - anchor)
                let now = startNs + elapsed
                if now >= self.durationNs {
                    self.timeNs = self.durationNs
                    self.requestFrame(at: self.durationNs)
                    self.pause()
                    return
                }
                self.timeNs = now
                self.requestFrame(at: now)
                try? await Task.sleep(for: .milliseconds(33))
            }
        }
    }

    func pause() {
        isPlaying = false
        playbackTask?.cancel()
        playbackTask = nil
        enqueueAudio { await $0.stop() }
        // Back to full quality for the parked frame.
        enqueueOutputSize(previewOutputSize(), renderAt: timeNs)
    }

    func seek(to newTimeNs: Int64) {
        let clamped = max(0, min(newTimeNs, durationNs))
        let wasPlaying = isPlaying
        if wasPlaying { pause() }
        noteScrubActivity()
        timeNs = clamped
        requestFrame(at: clamped)
        // Scrubbing to the very end parks there; play() would wrap to 0.
        if wasPlaying, clamped < durationNs { play() }
    }

    /// Scrub-adaptive quality: rapid seeks render at half resolution —
    /// full-res 5K CoreImage frames per drag tick contend with
    /// WindowServer for the GPU and stutter the whole system — then the
    /// parked frame settles back to full quality 350 ms after the last
    /// seek. Same FIFO'd size chain as playback, so ordering holds.
    private var scrubSettleTask: Task<Void, Never>?
    private var scrubbing = false

    private func noteScrubActivity() {
        guard !isPlaying else { return }
        if !scrubbing {
            scrubbing = true
            enqueueOutputSize(previewOutputSize(halved: true))
        }
        scrubSettleTask?.cancel()
        scrubSettleTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled, let self else { return }
            self.scrubbing = false
            self.enqueueOutputSize(self.previewOutputSize(), renderAt: self.timeNs)
        }
    }

    /// Render requests coalesce: at most one in flight, latest time wins.
    func requestFrame(at requestNs: Int64) {
        pendingRenderNs = requestNs
        guard !renderInFlight else { return }
        renderInFlight = true
        Task { [weak self] in
            while let self, let target = self.pendingRenderNs {
                self.pendingRenderNs = nil
                if let frame = await self.box.renderedFrame(at: target) {
                    self.currentFrame = frame.image
                }
            }
            self?.renderInFlight = false
        }
    }

    // MARK: - Edits

    func updateEdits(
        kind: String = "general",
        _ mutate: @escaping @Sendable (inout EditDocument) -> Void
    ) {
        history.recordBeforeEdit(
            edits, nowNs: Int64(DispatchTime.now().uptimeNanoseconds), kind: kind)
        refreshHistoryFlags()
        Task {
            do {
                self.edits = try await box.updateEdits(mutate)
                self.durationNs = await box.outputDurationNs
                self.timeNs = min(self.timeNs, max(0, self.durationNs - 1))
                self.remapWaveform()
                ProjectThumbnailer.invalidate(for: self.projectURL)
                self.enqueueOutputSize(
                    self.previewOutputSize(halved: self.isPlaying),
                    renderAt: self.timeNs)
            } catch {
                // The document never changed: withdraw the history step so
                // ⌘Z doesn't replay a no-op.
                self.history.discardLastPush()
                self.refreshHistoryFlags()
                self.loadError = "Edit save failed: \(error)"
            }
        }
    }

    private func refreshHistoryFlags() {
        canUndo = history.canUndo
        canRedo = history.canRedo
    }

    /// Restore a history snapshot without recording a new step.
    private func applySnapshot(_ snapshot: EditDocument) {
        // Selections may point at zooms/clips the snapshot no longer has;
        // leaving them makes delete/aim silently dead (or worse, pushes
        // no-op undo steps).
        if let id = selectedClipID,
            !snapshot.clips.contains(where: { $0.id == id })
        {
            selectedClipID = nil
        }
        if let id = selectedZoomID,
            !snapshot.zooms.contains(where: { $0.id == id })
        {
            selectedZoomID = nil
        }
        Task {
            do {
                self.edits = try await box.updateEdits { $0 = snapshot }
                self.durationNs = await box.outputDurationNs
                self.timeNs = min(self.timeNs, max(0, self.durationNs - 1))
                self.remapWaveform()
                ProjectThumbnailer.invalidate(for: self.projectURL)
                self.enqueueOutputSize(
                    self.previewOutputSize(halved: self.isPlaying),
                    renderAt: self.timeNs)
            } catch {
                self.loadError = "Undo failed: \(error)"
            }
        }
    }

    /// Selection for the clip lane.
    var selectedClipID: UUID?

    /// Whether the project has any microphone audio at all.
    private(set) var hasMicAudio = false

    /// Whether the recording captured keystroke events (shortcut overlay).
    private(set) var hasKeystrokes = false

    // MARK: Captions

    private(set) var captions: [CaptionCue] = []
    private(set) var captionStatus: String?
    private(set) var isTranscribing = false

    /// On-device transcription of the mic track (one-time authorization).
    func transcribe() {
        guard !isTranscribing else { return }
        isTranscribing = true
        captionStatus = "Transcribing on-device…"
        Task {
            defer { self.isTranscribing = false }
            guard await Transcriber.requestAuthorization() else {
                self.captionStatus = Transcriber.TranscriberError.notAuthorized.description
                return
            }
            do {
                let segments = await box.micSegments
                let layout = await box.layout
                let cues = try await Transcriber.transcribeMicTrack(
                    segments: segments, layout: layout,
                    progress: { fraction in
                        Task { @MainActor [weak self] in
                            self?.captionStatus = String(
                                format: "Transcribing on-device… %.0f%%", fraction * 100)
                        }
                    })
                self.captions = cues
                self.persistCaptions()
                self.captionStatus = cues.isEmpty
                    ? "No speech recognized in the mic track."
                    : "\(cues.count) caption cue\(cues.count == 1 ? "" : "s") ready."
            } catch {
                self.captionStatus = "\(error)"
            }
        }
    }

    /// Update one cue's text from the transcript editor; persists debounced.
    func setCaptionText(_ text: String, cueID: UUID) {
        guard let index = captions.firstIndex(where: { $0.id == cueID }) else { return }
        guard captions[index].text != text else { return }
        captions[index].text = text
        captionSaveTask?.cancel()
        captionSaveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard !Task.isCancelled else { return }
            self?.persistCaptions()
        }
    }

    /// Jump the playhead to a cue. Cue times are SOURCE time; the seek
    /// happens in output time so cuts and speeds are respected.
    func seekToCue(_ cue: CaptionCue) {
        seek(to: effectiveClipTimeline.outputTimeSnapped(forSource: cue.startNs))
    }

    private var captionSaveTask: Task<Void, Never>?

    private func persistCaptions() {
        let cues = captions
        Task {
            let layout = await self.box.layout
            try? CaptionStore.save(cues, to: layout)
        }
    }

    /// Cues on the OUTPUT timeline (cuts, speeds, and trim applied —
    /// exactly the range the exporter renders).
    private func exportCues() -> [CaptionCue] {
        let timeline = effectiveClipTimeline
        let total = timeline.outputDurationNs
        let start = max(0, edits.trimStartNs ?? 0)
        let end = min(total, edits.trimEndNs ?? total)
        return CaptionWriter.clipped(
            CaptionWriter.remapped(captions, through: timeline),
            toRange: (min(start, end), max(start, end)))
    }

    /// Serialized captions for export; nil (with a status explaining why)
    /// when every cue falls outside the edited range — a 0-byte SRT helps
    /// nobody.
    func captionTextForExport(format: CaptionFormat) -> String? {
        let cues = exportCues()
        guard !cues.isEmpty else {
            captionStatus =
                "All cues fall outside the edited range — nothing to export."
            return nil
        }
        return CaptionWriter.serialize(cues, format: format)
    }

    var effectiveClipTimeline: ClipTimeline {
        ClipTimeline(clips: edits.clips, sourceDurationNs: sourceDurationNs)
    }

    /// All clip mutations funnel here: trims are stored in OUTPUT time, so
    /// every clip change must remap them through old→source→new timelines
    /// or a ripple delete earlier in the file silently shifts what the trim
    /// cuts. (Clip ops read the main-actor `edits` copy; they are user
    /// gestures and cannot burst faster than the box round-trip.)
    private func applyClips(_ newClips: [Clip], kind: String) {
        let oldTimeline = effectiveClipTimeline
        let newTimeline = ClipTimeline(
            clips: newClips, sourceDurationNs: sourceDurationNs)
        let oldOutputEnd = oldTimeline.outputDurationNs
        let newOutputEnd = newTimeline.outputDurationNs
        updateEdits(kind: kind) { edits in
            if let trim = edits.trimStartNs {
                edits.trimStartNs = newTimeline.outputTimeSnapped(
                    forSource: oldTimeline.sourceTime(forOutput: trim))
            }
            if let trim = edits.trimEndNs {
                // The exclusive end at exactly the old duration means "to
                // the end"; converting through source time would clamp it
                // to end − 1 ns.
                edits.trimEndNs = trim >= oldOutputEnd
                    ? newOutputEnd
                    : newTimeline.outputTimeSnapped(
                        forSource: oldTimeline.sourceTime(forOutput: trim))
            }
            edits.clips = newClips
        }
    }

    /// Split the clip under the playhead (S).
    func splitAtPlayhead() {
        let timeline = effectiveClipTimeline
        let split = timeline.splitting(atOutput: timeNs)
        guard split.count != timeline.clips.count else { return }
        applyClips(split, kind: "clip-split")
    }

    /// Set one clip's playback rate.
    func setClipSpeed(_ speed: Double, clipID: UUID) {
        applyClips(
            effectiveClipTimeline.settingSpeed(speed, clipID: clipID),
            kind: "clip-speed")
    }

    /// Feedback line for the clips panel (detection progress/refusals).
    private(set) var clipStatus: String?

    /// Auto-detect dead stretches (idle cursor + quiet audio) and speed
    /// them 4×. One undo step. Returns the number of spans applied.
    func detectAndSpeedDeadStretches() async -> Int {
        // The waveform decodes in a background task after open. Without it
        // the detector would treat narration-over-still-slides as "quiet"
        // and speed (and silence!) spans the lecturer was talking through.
        if hasMicAudio, sourceWaveform.isEmpty {
            clipStatus = "Audio analysis is still loading — try again in a moment."
            return 0
        }
        clipStatus = nil
        let digest = await box.activityDigest()
        let inputs = DeadStretchDetector.Inputs(
            clickTimesNs: digest.clicks,
            cursorSamples: digest.cursor.map { ($0.0, $0.1, $0.2) },
            audioLevels: sourceWaveform,
            sourceDurationNs: sourceDurationNs)
        let spans = DeadStretchDetector.detect(inputs)
        guard !spans.isEmpty else { return 0 }
        let clips = DeadStretchDetector.applying(
            spans: spans, to: effectiveClipTimeline)
        applyClips(clips, kind: "clip-dead-stretch")
        return spans.count
    }

    /// Ripple-delete the selected clip (X / ⌫).
    func deleteSelectedClip() {
        guard let id = selectedClipID else { return }
        let timeline = effectiveClipTimeline
        let remaining = timeline.deleting(clipID: id)
        guard remaining.count != timeline.clips.count else { return }
        selectedClipID = nil
        applyClips(remaining, kind: "clip-delete")
    }

    /// Click-to-aim: set the selected zoom's focal to the clicked point.
    func aimSelectedZoom(atViewFraction fraction: CGPoint) {
        guard let zoomID = selectedZoomID,
            let current = edits.zooms.first(where: { $0.id == zoomID })
        else { return }  // stale selection: no edit, no undo step
        Task {
            let focal = await box.sourceFocal(
                atCanvasFraction: fraction, outputNs: timeNs)
            // A focus-grabbing click that lands where the focal already is
            // should not dirty the document or push history.
            guard abs(current.focalX - focal.x) > 0.004
                || abs(current.focalY - focal.y) > 0.004
            else { return }
            self.updateEdits(kind: "zoom-aim") { edits in
                if let index = edits.zooms.firstIndex(where: { $0.id == zoomID }) {
                    edits.zooms[index].focalX = focal.x
                    edits.zooms[index].focalY = focal.y
                }
            }
        }
    }

    /// Drop the camera PiP into the quadrant of the released point.
    func placeCameraPiP(atViewFraction fraction: CGPoint) {
        guard hasCamera else { return }
        let corner: CameraStyle.Corner =
            fraction.y < 0.5
            ? (fraction.x < 0.5 ? .topLeft : .topRight)
            : (fraction.x < 0.5 ? .bottomLeft : .bottomRight)
        guard corner != edits.camera.corner else { return }
        updateEdits { $0.camera.corner = corner }
    }

    func undo() {
        guard let snapshot = history.undo(current: edits) else { return }
        refreshHistoryFlags()
        applySnapshot(snapshot)
    }

    func redo() {
        guard let snapshot = history.redo(current: edits) else { return }
        refreshHistoryFlags()
        applySnapshot(snapshot)
    }

    func regenerateZooms() {
        history.recordBeforeEdit(
            edits, nowNs: Int64(DispatchTime.now().uptimeNanoseconds))
        refreshHistoryFlags()
        Task {
            do {
                self.edits = try await box.regenerateZooms()
                self.requestFrame(at: self.timeNs)
            } catch {
                self.loadError = "Zoom regeneration failed: \(error)"
            }
        }
    }

    // MARK: - Export

    private var exportTask: Task<Void, Never>?

    /// Lecturer-oriented one-click export quality presets. Studio = 1:1 native content; Web/Compact trade
    /// size for upload friendliness.
    enum ExportPreset: String, CaseIterable, Identifiable {
        case studio, web1080, compact720
        var id: String { rawValue }
        var label: String {
            switch self {
            case .studio: return "Studio"
            case .web1080: return "Web 1080p"
            case .compact720: return "Compact 720p"
            }
        }
        var height: Int? {
            switch self {
            case .studio: return nil
            case .web1080: return 1080
            case .compact720: return 720
            }
        }
        var bitsPerPixelPerFrame: Double {
            switch self {
            case .studio: return 0.16
            case .web1080: return 0.12
            case .compact720: return 0.10
            }
        }
        var detail: String {
            switch self {
            case .studio: return "Native pixels, highest quality"
            case .web1080: return "1080p, great for LMS/YouTube"
            case .compact720: return "720p, smallest upload"
            }
        }
    }

    func export(
        to outputURL: URL, styled: Bool, height: Int?,
        bitsPerPixelPerFrame: Double = 0.16,
        checkpointed: Bool = false
    ) {
        if case .running = exportState { return }
        exportState = .running(stage: styled ? "render" : "video", fraction: 0)
        let projectURL = self.projectURL
        // Strong self: the player must outlive its export.
        let setState: @Sendable (ExportState) -> Void = { state in
            Task { @MainActor in self.exportState = state }
        }
        exportTask = Task.detached {
            do {
                let progress: @Sendable (String, Double) -> Void = { stage, fraction in
                    setState(.running(stage: stage, fraction: fraction))
                }
                if styled, checkpointed {
                    // Resumable: a crash or quit mid-export keeps its
                    // committed segments; re-exporting resumes them.
                    _ = try await CheckpointedExporter.export(
                        projectAt: projectURL, to: outputURL,
                        options: .init(
                            bitsPerPixelPerFrame: bitsPerPixelPerFrame,
                            outputHeight: height,
                            overwrite: true, progress: progress))
                } else if styled {
                    _ = try await StyledExporter.export(
                        projectAt: projectURL, to: outputURL,
                        options: .init(
                            bitsPerPixelPerFrame: bitsPerPixelPerFrame,
                            outputHeight: height,
                            overwrite: true, progress: progress))
                } else {
                    _ = try await SegmentAssembler.assemble(
                        projectAt: projectURL, to: outputURL,
                        options: .init(overwrite: true, progress: progress))
                }
                setState(.done(outputURL))
            } catch is CancellationError {
                setState(.idle)  // cancelled cleanly; nothing was left behind
            } catch {
                setState(.failed("\(error)"))
            }
        }
    }

    /// Animated-GIF export: same composition graph, palette container.
    func exportGIF(to outputURL: URL) {
        if case .running = exportState { return }
        exportState = .running(stage: "gif", fraction: 0)
        let projectURL = self.projectURL
        let setState: @Sendable (ExportState) -> Void = { state in
            Task { @MainActor in self.exportState = state }
        }
        exportTask = Task.detached {
            do {
                _ = try await GIFExporter.export(
                    projectURL: projectURL, to: outputURL,
                    options: .init(overwrite: true),
                    progress: { fraction in
                        setState(.running(stage: "gif", fraction: fraction))
                    })
                setState(.done(outputURL))
            } catch is CancellationError {
                setState(.idle)
            } catch {
                setState(.failed("\(error)"))
            }
        }
    }

    func cancelExport() {
        exportTask?.cancel()
    }
}

// StyledExporter/SegmentAssembler live in ExportEngine.
import ExportEngine

/// Raw audio preview: microphone AND system-audio segments scheduled at
/// their timeline offsets, one player node per track (formats differ).
/// Export mixes both tracks, so preview schedules both.
actor AudioPreview {
    private struct Track {
        let player: AVAudioPlayerNode
        let files: [(startNs: Int64, file: AVAudioFile)]
    }

    private let engine = AVAudioEngine()
    private var tracks: [Track] = []
    private var prepared = false

    func prepare(
        micSegments: [SegmentDescriptor],
        systemSegments: [SegmentDescriptor],
        layout: ProjectLayout
    ) {
        guard tracks.isEmpty else { return }  // re-prepare would double audio
        // INVARIANT: every file within one track shares one sample rate
        // (one AudioSegmentWriter per track per session writes a constant
        // header rate for its whole life), so connecting at files[0]'s
        // format and scheduling with per-file rates always agree. If mixed
        // rates ever appear in a track, both assumptions break together.
        for segments in [micSegments, systemSegments] {
            let files: [(startNs: Int64, file: AVAudioFile)] = segments
                .compactMap { segment in
                    guard let url = try? layout.resolve(relativePath: segment.path),
                        let file = try? AVAudioFile(forReading: url)
                    else { return nil }
                    return (segment.normalizedStartNs, file)
                }
            guard !files.isEmpty else { continue }
            let player = AVAudioPlayerNode()
            engine.attach(player)
            engine.connect(
                player, to: engine.mainMixerNode,
                format: files[0].file.processingFormat)
            tracks.append(Track(player: player, files: files))
        }
        prepared = !tracks.isEmpty
    }

    /// Schedule exactly the planned spans: cuts skip, sped spans stay
    /// silent, kept 1× spans play their source audio at their output
    /// offsets — the export audio pump's policy, applied to preview.
    func play(plan: [AudioScheduleEntry]) {
        guard prepared else { return }
        stop()
        do {
            try engine.start()
        } catch {
            return
        }
        for track in tracks {
            schedule(plan: plan, on: track)
            track.player.play()
        }
    }

    private func schedule(plan: [AudioScheduleEntry], on track: Track) {
        for entry in plan {
            let entrySourceEndNs = entry.sourceStartNs + entry.lengthNs
            for (segmentStartNs, file) in track.files {
                let sampleRate = file.processingFormat.sampleRate
                let segmentEndNs = segmentStartNs
                    + Int64(Double(file.length) / sampleRate * 1e9)
                let readStartNs = max(entry.sourceStartNs, segmentStartNs)
                let readEndNs = min(entrySourceEndNs, segmentEndNs)
                guard readEndNs > readStartNs else { continue }
                let skipFrames = AVAudioFramePosition(
                    Double(readStartNs - segmentStartNs) / 1e9 * sampleRate)
                let frameCount = AVAudioFrameCount(
                    Double(readEndNs - readStartNs) / 1e9 * sampleRate)
                guard frameCount > 0 else { continue }
                // Inside a kept 1× span, source ns == output ns.
                let whenNs = entry.outputOffsetNs
                    + (readStartNs - entry.sourceStartNs)
                let when = AVAudioTime(
                    sampleTime: AVAudioFramePosition(
                        Double(whenNs) / 1e9 * sampleRate),
                    atRate: sampleRate)
                track.player.scheduleSegment(
                    file, startingFrame: skipFrames, frameCount: frameCount,
                    at: when)
            }
        }
    }

    func stop() {
        for track in tracks { track.player.stop() }
        engine.stop()
    }
}
