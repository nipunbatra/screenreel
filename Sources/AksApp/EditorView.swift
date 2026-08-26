import AppKit
import Captions
import SwiftUI
import TimelineCore

struct EditorView: View {
    @Environment(AppModel.self) private var model
    @Bindable var player: PreviewPlayer

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                previewCanvas
                transportBar
                TimeRuler(durationNs: player.durationNs)
                    .frame(height: 16)
                    .padding(.horizontal, 16)
                TimelineStrip(player: player)
                    .frame(height: 92)
                    .padding(.horizontal, 16)
                    .padding(.top, 2)
                    .padding(.bottom, 14)
            }
            .frame(minWidth: 560, maxWidth: .infinity)
            .background(Color.editorBackdrop)

            Divider().overlay(.white.opacity(0.08))
            InspectorView(player: player, exportRequested: $exportRequested)
                .frame(width: 312)
                .background(Color.editorBackdrop)
        }
        .sheet(isPresented: $showPalette) {
            CommandPaletteView(commands: paletteCommands, isPresented: $showPalette)
        }
        .background(
            // Invisible ⌘K target that works from anywhere in the editor.
            Button("") { showPalette = true }
                .keyboardShortcut("k", modifiers: .command)
                .hidden())
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button {
                    model.closeEditor()
                } label: {
                    Label("Recordings", systemImage: "chevron.left")
                }
            }
            ToolbarItem(placement: .principal) {
                Text(player.projectURL.deletingPathExtension().lastPathComponent)
                    .font(.headline)
            }
            ToolbarItemGroup {
                Button {
                    player.undo()
                } label: {
                    Label("Undo", systemImage: "arrow.uturn.backward")
                }
                .disabled(!player.canUndo)
                .keyboardShortcut("z", modifiers: .command)
                .help("Undo edit (⌘Z)")
                Button {
                    player.redo()
                } label: {
                    Label("Redo", systemImage: "arrow.uturn.forward")
                }
                .disabled(!player.canRedo)
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .help("Redo edit (⇧⌘Z)")
            }
            ToolbarItem(placement: .primaryAction) {
                if case .running(_, let fraction) = player.exportState {
                    ProgressView(value: fraction)
                        .frame(width: 120)
                } else {
                    Button {
                        exportRequested = true
                    } label: {
                        Label("Export", systemImage: "square.and.arrow.up")
                    }
                    .keyboardShortcut("e")
                }
            }
        }
    }

    /// Toolbar Export routes into the inspector's export flow.
    @State private var exportRequested = false
    @State private var showPalette = false
    @FocusState private var previewFocused: Bool

    private var paletteCommands: [PaletteCommand] {
        [
            PaletteCommand(
                title: player.isPlaying ? "Pause" : "Play",
                icon: "playpause", hint: "space") { player.togglePlay() },
            PaletteCommand(title: "Split clip at playhead", icon: "scissors", hint: "S") {
                player.splitAtPlayhead()
            },
            PaletteCommand(title: "Ripple-delete selected clip", icon: "rectangle.slash", hint: "X") {
                player.deleteSelectedClip()
            },
            PaletteCommand(title: "Detect dead stretches (4×)", icon: "hare", hint: nil) {
                Task { _ = await player.detectAndSpeedDeadStretches() }
            },
            PaletteCommand(title: "Undo", icon: "arrow.uturn.backward", hint: "⌘Z") {
                player.undo()
            },
            PaletteCommand(title: "Redo", icon: "arrow.uturn.forward", hint: "⇧⌘Z") {
                player.redo()
            },
            PaletteCommand(title: "Transcribe captions (on-device)", icon: "captions.bubble", hint: nil) {
                player.transcribe()
            },
            PaletteCommand(title: "Export styled MP4", icon: "square.and.arrow.up", hint: "⌘E") {
                exportRequested = true
            },
            PaletteCommand(title: "Regenerate auto-zooms", icon: "plus.magnifyingglass", hint: nil) {
                player.regenerateZooms()
            },
            PaletteCommand(
                title: player.edits.cursor.clickRipplesEnabled
                    ? "Hide click ripples" : "Show click ripples",
                icon: "circle.circle", hint: nil
            ) {
                let next = !player.edits.cursor.clickRipplesEnabled
                player.updateEdits { $0.cursor.clickRipples = next }
            },
            PaletteCommand(
                title: player.edits.camera.introNs > 0
                    ? "Camera intro: off" : "Camera intro: 5 s",
                icon: "person.crop.rectangle", hint: nil
            ) {
                let next: Int64 = player.edits.camera.introNs > 0
                    ? 0 : 5_000_000_000
                player.updateEdits(kind: "camera-intro") {
                    $0.camera.introNs = next
                }
            },
            PaletteCommand(title: "Set trim start here", icon: "timeline.selection", hint: nil) {
                let time = player.timeNs
                player.updateEdits { $0.trimStartNs = time }
            },
            PaletteCommand(title: "Set trim end here", icon: "timeline.selection", hint: nil) {
                let time = player.timeNs
                player.updateEdits { $0.trimEndNs = time }
            },
            PaletteCommand(title: "Back to recordings", icon: "chevron.left", hint: nil) {
                model.closeEditor()
            },
        ]
    }

    @Environment(\.displayScale) private var displayScale

    private var previewCanvas: some View {
        GeometryReader { proxy in
            previewContent
                .onAppear {
                    player.setPreviewSurface(
                        pointSize: proxy.size, displayScale: displayScale)
                }
                .onChange(of: proxy.size) { _, size in
                    player.setPreviewSurface(
                        pointSize: size, displayScale: displayScale)
                }
        }
    }

    private var previewContent: some View {
        ZStack {
            Color.canvasBackdrop
            if let frame = player.currentFrame ?? player.placeholder {
                GeometryReader { imageProxy in
                    Image(decorative: frame, scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .strokeBorder(.white.opacity(0.08)))
                        .shadow(color: .black.opacity(0.55), radius: 24, y: 10)
                        // Direct manipulation on the frame itself:
                        // click aims the SELECTED zoom's focal point;
                        // drag-release drops the camera PiP into that
                        // quadrant.
                        .gesture(
                            SpatialTapGesture()
                                .onEnded { value in
                                    previewFocused = true
                                    // The placeholder thumbnail's aspect can
                                    // predate the current canvas reframe;
                                    // aiming through it would mis-map.
                                    guard player.currentFrame != nil,
                                        let fraction = Self.imageFraction(
                                            point: value.location,
                                            container: imageProxy.size,
                                            image: CGSize(
                                                width: CGFloat(frame.width),
                                                height: CGFloat(frame.height)))
                                    else { return }
                                    player.aimSelectedZoom(atViewFraction: fraction)
                                })
                        .gesture(
                            DragGesture(minimumDistance: 24)
                                .onEnded { value in
                                    guard player.selectedZoomID == nil,
                                        let fraction = Self.imageFraction(
                                            point: value.location,
                                            container: imageProxy.size,
                                            image: CGSize(
                                                width: CGFloat(frame.width),
                                                height: CGFloat(frame.height)))
                                    else { return }
                                    player.placeCameraPiP(atViewFraction: fraction)
                                })
                }
                .padding(24)
                    .overlay(alignment: .bottomTrailing) {
                        if player.currentFrame == nil {
                            ProgressView()
                                .controlSize(.small)
                                .padding(36)
                        }
                    }
            } else {
                ProgressView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .focusable()
        .focused($previewFocused)
        .onKeyPress(.leftArrow) {
            player.seek(to: player.timeNs - 33_333_333)
            return .handled
        }
        .onKeyPress(.rightArrow) {
            player.seek(to: player.timeNs + 33_333_333)
            return .handled
        }
        .onKeyPress(.upArrow) {
            player.seek(to: player.timeNs - 5_000_000_000)
            return .handled
        }
        .onKeyPress(.downArrow) {
            player.seek(to: player.timeNs + 5_000_000_000)
            return .handled
        }
    }

    private var transportBar: some View {
        HStack(spacing: 14) {
            HStack(spacing: 6) {
                Button {
                    player.seek(to: player.timeNs - 33_333_333)
                } label: {
                    Image(systemName: "backward.frame.fill")
                        .font(.footnote)
                        .frame(width: 26, height: 26)
                        .background(.white.opacity(0.06), in: Circle())
                }
                .buttonStyle(.plain)
                .help("Previous frame (←)")
                Button {
                    player.togglePlay()
                } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title3)
                        .frame(width: 34, height: 34)
                        .background(.white.opacity(0.1), in: Circle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.space, modifiers: [])
                .help("Play/Pause (space)")
                Button {
                    player.seek(to: player.timeNs + 33_333_333)
                } label: {
                    Image(systemName: "forward.frame.fill")
                        .font(.footnote)
                        .frame(width: 26, height: 26)
                        .background(.white.opacity(0.06), in: Circle())
                }
                .buttonStyle(.plain)
                .help("Next frame (→)")

                Divider().frame(height: 18)

                Button {
                    player.splitAtPlayhead()
                } label: {
                    Image(systemName: "scissors")
                        .font(.footnote)
                        .frame(width: 26, height: 26)
                        .background(.white.opacity(0.06), in: Circle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut("s", modifiers: [])
                .help("Split clip at playhead (S)")
                Button {
                    player.deleteSelectedClip()
                } label: {
                    Image(systemName: "rectangle.slash")
                        .font(.footnote)
                        .frame(width: 26, height: 26)
                        .background(.white.opacity(0.06), in: Circle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut("x", modifiers: [])
                .disabled(player.selectedClipID == nil)
                .help("Ripple-delete selected clip (X)")
            }

            Text(EditorView.timeText(player.timeNs))
                .font(.callout.monospacedDigit().weight(.medium))

            Slider(
                value: Binding(
                    get: { Double(player.timeNs) },
                    set: { player.seek(to: Int64($0)) }),
                in: 0...Double(max(player.durationNs, 1)))

            Text(EditorView.timeText(player.durationNs))
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    /// Point in the container → fraction within the aspect-fitted image
    /// rect; nil when the point falls in the letterbox area.
    static func imageFraction(
        point: CGPoint, container: CGSize, image: CGSize
    ) -> CGPoint? {
        guard image.width > 0, image.height > 0,
            container.width > 0, container.height > 0
        else { return nil }
        let scale = min(container.width / image.width, container.height / image.height)
        let shown = CGSize(width: image.width * scale, height: image.height * scale)
        let origin = CGPoint(
            x: (container.width - shown.width) / 2,
            y: (container.height - shown.height) / 2)
        let local = CGPoint(x: point.x - origin.x, y: point.y - origin.y)
        guard local.x >= 0, local.y >= 0,
            local.x <= shown.width, local.y <= shown.height
        else { return nil }
        return CGPoint(x: local.x / shown.width, y: local.y / shown.height)
    }

    static func timeText(_ ns: Int64) -> String {
        let totalSeconds = Double(ns) / 1e9
        let minutes = Int(totalSeconds) / 60
        let seconds = totalSeconds - Double(minutes * 60)
        return String(format: "%d:%05.2f", minutes, seconds)
    }
}

// MARK: - Timeline

/// Second/minute tick marks over the timeline, adaptive to duration.
struct TimeRuler: View {
    let durationNs: Int64

    var body: some View {
        Canvas { context, size in
            let seconds = Double(durationNs) / 1e9
            guard seconds > 0.2, size.width > 60 else { return }
            // Integer tick indices (never accumulated floats), and a label
            // step widened until labels cannot collide at this width.
            let step = TimelineRuler.labelStep(forDuration: seconds, width: size.width)
            let minor = step / 4
            let tickCount = Int(seconds / minor)
            guard tickCount >= 1 else { return }
            for index in 0...tickCount {
                let t = Double(index) * minor
                let x = size.width * t / seconds
                let isMajor = index % 4 == 0
                let height: Double = isMajor ? 7 : 3.5
                context.fill(
                    Path(CGRect(x: x - 0.5, y: size.height - height, width: 1, height: height)),
                    with: .color(.white.opacity(isMajor ? 0.38 : 0.14)))
                // Label majors only, and never within the last 44 pt where
                // the text would clip at the edge.
                if isMajor, x + 44 < size.width {
                    let minutes = Int(t) / 60
                    let secs = Int(t) % 60
                    let label = Text(String(format: "%d:%02d", minutes, secs))
                        .font(.system(size: 9, weight: .medium).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.45))
                    context.draw(label, at: CGPoint(x: x + 4, y: 1), anchor: .topLeading)
                }
            }
        }
    }
}

/// Zoom blocks are selectable, draggable (move), and resizable at their
/// edges; the math lives in `ZoomSegment` and is unit-tested.
struct TimelineStrip: View {
    @Bindable var player: PreviewPlayer

    private enum DragKind {
        case move, resizeStart, resizeEnd
    }
    @State private var dragKind: DragKind?
    @State private var dragOriginal: ZoomSegment?
    @State private var dragPreview: ZoomSegment?

    var body: some View {
        GeometryReader { geometry in
            strip(width: geometry.size.width)
        }
    }

    @ViewBuilder
    private func strip(width: Double) -> some View {
        let duration = Double(max(player.durationNs, 1))
        let x: (Int64) -> Double = { ns in width * Double(ns) / duration }
        let ns: (Double) -> Int64 = { position in Int64(position / width * duration) }

        let clipTimeline = player.effectiveClipTimeline
        ZStack(alignment: .topLeading) {
                // Track background; click to seek.
                RoundedRectangle(cornerRadius: 8)
                    .fill(.white.opacity(0.06))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(.white.opacity(0.08)))
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                player.seek(to: ns(value.location.x))
                            })

                // Clip lane (top): one block per kept span; click selects,
                // context menu splits/deletes. Cuts show as block breaks.
                ForEach(Array(clipTimeline.clips.enumerated()), id: \.element.id) { index, clip in
                    let startX = x(clipTimeline.outputStart(ofClipAt: index))
                    let endX = x(clipTimeline.outputStart(ofClipAt: index) + clip.outputLengthNs)
                    let selected = player.selectedClipID == clip.id
                    RoundedRectangle(cornerRadius: 5)
                        .fill(selected
                            ? Color.orange.opacity(0.55)
                            : Color.white.opacity(0.14))
                        .overlay(
                            RoundedRectangle(cornerRadius: 5)
                                .strokeBorder(
                                    selected ? Color.orange : .white.opacity(0.25),
                                    lineWidth: selected ? 1.5 : 1))
                        .frame(width: max(6, endX - startX - 2), height: 18)
                        .offset(x: startX + 1, y: 2)
                        .overlay(alignment: .center) {
                            if abs(clip.speed - 1) > 0.001 {
                                Text(String(format: clip.speed == clip.speed.rounded()
                                    ? "%.0f×" : "%.1f×", clip.speed))
                                    .font(.system(size: 9, weight: .bold).monospacedDigit())
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 4)
                                    .background(.orange.opacity(0.85), in: Capsule())
                            }
                        }
                        .onTapGesture {
                            player.selectedClipID = selected ? nil : clip.id
                        }
                        .contextMenu {
                            Button("Split at playhead") { player.splitAtPlayhead() }
                            Menu("Speed") {
                                ForEach([1.0, 1.5, 2, 4, 8], id: \.self) { speed in
                                    Button(speed == 1 ? "1× (normal)"
                                        : String(format: speed == speed.rounded()
                                            ? "%.0f×" : "%.1f×", speed))
                                    {
                                        player.setClipSpeed(speed, clipID: clip.id)
                                    }
                                }
                            }
                            if clipTimeline.clips.count > 1 {
                                Button("Ripple delete", role: .destructive) {
                                    player.selectedClipID = clip.id
                                    player.deleteSelectedClip()
                                }
                            }
                        }
                }

                // Microphone waveform under the zoom lane.
                if !player.waveform.isEmpty {
                    WaveformView(peaks: player.waveform)
                        .allowsHitTesting(false)
                        .padding(.top, 24)
                        .padding(.bottom, 3)
                }

                // Trimmed-away shading.
                if let trimStart = player.edits.trimStartNs, trimStart > 0 {
                    Rectangle()
                        .fill(.black.opacity(0.5))
                        .frame(width: x(trimStart))
                        .allowsHitTesting(false)
                }
                if let trimEnd = player.edits.trimEndNs, trimEnd < player.durationNs {
                    Rectangle()
                        .fill(.black.opacity(0.5))
                        .frame(width: width - x(trimEnd))
                        .offset(x: x(trimEnd))
                        .allowsHitTesting(false)
                }

                // Zoom blocks (source-anchored, drawn at output positions).
                ForEach(player.edits.zooms) { zoom in
                    let shown = dragPreview?.id == zoom.id ? dragPreview! : zoom
                    zoomBlock(
                        shown, x: x, ns: ns, stripWidth: width,
                        clipTimeline: clipTimeline)
                }

                // Playhead.
                Rectangle()
                    .fill(.red)
                    .frame(width: 2, height: nil)
                    .offset(x: x(player.timeNs))
                    .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private func zoomBlock(
        _ zoom: ZoomSegment,
        x: (Int64) -> Double,
        ns: @escaping (Double) -> Int64,
        stripWidth: Double,
        clipTimeline: ClipTimeline
    ) -> some View {
        // Zooms are SOURCE-anchored; on the (possibly cut) timeline they
        // draw at their mapped output positions.
        let outStart = clipTimeline.outputTimeSnapped(forSource: zoom.startNs)
        let outEnd = clipTimeline.outputTimeSnapped(forSource: zoom.endNs)
        let blockX = x(outStart)
        let blockWidth = max(10, x(outEnd) - blockX)
        let selected = player.selectedZoomID == zoom.id

        RoundedRectangle(cornerRadius: 6)
            .fill(zoom.isActive
                ? Color.accentColor.opacity(selected ? 0.85 : 0.55)
                : Color.gray.opacity(0.3))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(selected ? .white : .white.opacity(0.25), lineWidth: selected ? 1.5 : 1))
            .overlay {
                HStack {
                    Image(systemName: "plus.magnifyingglass")
                        .font(.caption2)
                    if blockWidth > 70 {
                        Text(String(format: "%.1f×", zoom.scale))
                            .font(.caption2.monospacedDigit().weight(.semibold))
                    }
                }
                .foregroundStyle(.white.opacity(0.9))
            }
            .frame(width: blockWidth, height: 26)
            .offset(x: blockX, y: 62)
            .gesture(
                DragGesture(minimumDistance: 2)
                    .onChanged { value in
                        if dragOriginal?.id != zoom.id {
                            dragOriginal = zoom
                            let grabX = value.startLocation.x - blockX
                            dragKind = grabX < 10
                                ? .resizeStart
                                : (grabX > blockWidth - 10 ? .resizeEnd : .move)
                            player.selectedZoomID = zoom.id
                        }
                        guard let original = dragOriginal, let kind = dragKind else { return }
                        let deltaNs = ns(value.translation.width) - ns(0)
                        switch kind {
                        case .move:
                            // Map the dragged OUTPUT position back to a
                            // source anchor so moves stay correct across
                            // cuts.
                            let outOriginal = clipTimeline.outputTimeSnapped(
                                forSource: original.startNs)
                            let targetSource = clipTimeline.sourceTime(
                                forOutput: max(0, outOriginal + deltaNs))
                            dragPreview = original.moved(
                                byNs: targetSource - original.startNs,
                                durationNs: player.sourceDurationNs)
                        case .resizeStart:
                            dragPreview = original.resizingStart(byNs: deltaNs)
                        case .resizeEnd:
                            dragPreview = original.resizingEnd(
                                byNs: deltaNs, durationNs: player.sourceDurationNs)
                        }
                    }
                    .onEnded { _ in
                        if let preview = dragPreview {
                            player.updateEdits { edits in
                                if let index = edits.zooms.firstIndex(where: { $0.id == preview.id }) {
                                    edits.zooms[index] = preview
                                }
                                edits.zooms.sort { $0.startNs < $1.startNs }
                            }
                        }
                        dragPreview = nil
                        dragOriginal = nil
                        dragKind = nil
                    })
            .onTapGesture {
                player.selectedZoomID = selected ? nil : zoom.id
                player.seek(to: clipTimeline.outputTimeSnapped(
                    forSource: zoom.startNs) + 1_000_000)
            }
            .contextMenu {
                Button("Duplicate after") {
                    let copy = zoom.duplicatedAfter(durationNs: player.sourceDurationNs)
                    player.updateEdits { edits in
                        edits.zooms.append(copy)
                        edits.zooms.sort { $0.startNs < $1.startNs }
                    }
                    player.selectedZoomID = copy.id
                }
                Button("Jump here") {
                    player.seek(to: player.effectiveClipTimeline
                        .outputTimeSnapped(forSource: zoom.startNs) + 1_000_000)
                }
                Divider()
                Button("Delete", role: .destructive) {
                    player.updateEdits { edits in
                        edits.zooms.removeAll { $0.id == zoom.id }
                    }
                    if player.selectedZoomID == zoom.id { player.selectedZoomID = nil }
                }
                Button("Delete all zooms", role: .destructive) {
                    player.updateEdits { edits in
                        edits.zooms.removeAll()
                        edits.autoZoomEnabled = false
                    }
                    player.selectedZoomID = nil
                }
            }
    }
}

/// Mirrored peak bars.
struct WaveformView: View {
    let peaks: [Float]

    var body: some View {
        Canvas { context, size in
            guard !peaks.isEmpty else { return }
            let barWidth = size.width / Double(peaks.count)
            let midY = size.height / 2
            var path = Path()
            for (index, peak) in peaks.enumerated() {
                let height = max(1, Double(peak) * size.height * 0.9)
                path.addRect(CGRect(
                    x: Double(index) * barWidth,
                    y: midY - height / 2,
                    width: max(0.5, barWidth * 0.7),
                    height: height))
            }
            context.fill(path, with: .color(.white.opacity(0.22)))
        }
    }
}

// MARK: - Inspector

struct InspectorView: View {
    @Bindable var player: PreviewPlayer
    @Binding var exportRequested: Bool
    @State private var presetStore = StylePresetStore()
    @State private var newPresetName = ""
    @State private var showTranscript = false
    @State private var resumableExport = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                backgroundSection
                canvasSection
                screenSection
                if player.hasCamera {
                    cameraSection
                }
                cursorSection
                clipsSection
                audioSection
                captionsSection
                zoomSection
                trimSection
                presetSection
                exportSection
                if let error = player.loadError {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            }
            .padding(14)
        }
        .sheet(isPresented: $showTranscript) {
            TranscriptView(player: player, isPresented: $showTranscript)
        }
        .onChange(of: exportRequested) { _, requested in
            if requested {
                exportRequested = false
                runExport(styled: true)
            }
        }
    }

    // MARK: Background swatches

    private struct BackgroundPreset: Identifiable {
        let id: String
        let background: FrameStyle.Background
    }

    private static let presets: [BackgroundPreset] = [
        .init(id: "Navy", background: .linearGradient(
            top: .init(red: 0.16, green: 0.19, blue: 0.30),
            bottom: .init(red: 0.06, green: 0.07, blue: 0.12))),
        .init(id: "Sunset", background: .linearGradient(
            top: .init(red: 0.85, green: 0.42, blue: 0.25),
            bottom: .init(red: 0.35, green: 0.12, blue: 0.35))),
        .init(id: "Ocean", background: .linearGradient(
            top: .init(red: 0.10, green: 0.55, blue: 0.60),
            bottom: .init(red: 0.03, green: 0.15, blue: 0.30))),
        .init(id: "Meadow", background: .linearGradient(
            top: .init(red: 0.28, green: 0.55, blue: 0.33),
            bottom: .init(red: 0.05, green: 0.20, blue: 0.14))),
        .init(id: "Iris", background: .linearGradient(
            top: .init(red: 0.42, green: 0.35, blue: 0.80),
            bottom: .init(red: 0.13, green: 0.09, blue: 0.32))),
        .init(id: "Peach", background: .linearGradient(
            top: .init(red: 0.98, green: 0.70, blue: 0.55),
            bottom: .init(red: 0.85, green: 0.36, blue: 0.42))),
        .init(id: "Aurora", background: .linearGradient(
            top: .init(red: 0.15, green: 0.60, blue: 0.45),
            bottom: .init(red: 0.10, green: 0.15, blue: 0.45))),
        .init(id: "Rosé", background: .linearGradient(
            top: .init(red: 0.90, green: 0.55, blue: 0.70),
            bottom: .init(red: 0.42, green: 0.16, blue: 0.40))),
        .init(id: "Dawn", background: .linearGradient(
            top: .init(red: 0.95, green: 0.83, blue: 0.60),
            bottom: .init(red: 0.80, green: 0.45, blue: 0.35))),
        .init(id: "Midnight", background: .linearGradient(
            top: .init(red: 0.10, green: 0.11, blue: 0.16),
            bottom: .init(red: 0.02, green: 0.02, blue: 0.04))),
        .init(id: "Nebula", background: .mesh(
            base: .init(red: 0.10, green: 0.09, blue: 0.22),
            glow1: .init(red: 0.45, green: 0.30, blue: 0.90),
            glow2: .init(red: 0.10, green: 0.60, blue: 0.80))),
        .init(id: "Ember", background: .mesh(
            base: .init(red: 0.16, green: 0.07, blue: 0.10),
            glow1: .init(red: 0.95, green: 0.45, blue: 0.25),
            glow2: .init(red: 0.75, green: 0.15, blue: 0.45))),
        .init(id: "Lagoon", background: .mesh(
            base: .init(red: 0.04, green: 0.14, blue: 0.16),
            glow1: .init(red: 0.15, green: 0.75, blue: 0.65),
            glow2: .init(red: 0.10, green: 0.35, blue: 0.85))),
        .init(id: "Orchid", background: .mesh(
            base: .init(red: 0.14, green: 0.08, blue: 0.16),
            glow1: .init(red: 0.85, green: 0.40, blue: 0.75),
            glow2: .init(red: 0.40, green: 0.25, blue: 0.95))),
        .init(id: "Graphite", background: .solid(.init(red: 0.13, green: 0.13, blue: 0.15))),
        .init(id: "Paper", background: .solid(.init(red: 0.93, green: 0.92, blue: 0.90))),
        .init(id: "Snow", background: .solid(.init(red: 0.98, green: 0.98, blue: 0.99))),
        .init(id: "None", background: .none),
    ]

    private var backgroundSection: some View {
        Panel(title: "Background", icon: "paintpalette") {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 52, maximum: 60), spacing: 8)], spacing: 8) {
                ForEach(Self.presets) { preset in
                    swatch(preset)
                }
            }
        }
    }

    private func swatch(_ preset: BackgroundPreset) -> some View {
        let selected = player.edits.style.background == preset.background
        return Button {
            player.updateEdits { $0.style.background = preset.background }
        } label: {
            VStack(spacing: 4) {
                RoundedRectangle(cornerRadius: 7)
                    .fill(swatchStyle(preset.background))
                    .frame(height: 34)
                    .overlay { meshSwatchOverlay(preset.background) }
                    .overlay {
                        if case .none = preset.background {
                            Image(systemName: "slash.circle")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .overlay(
                        RoundedRectangle(cornerRadius: 7)
                            .strokeBorder(
                                selected ? Color.accentColor : .white.opacity(0.15),
                                lineWidth: selected ? 2 : 1))
                Text(preset.id)
                    .font(.caption2)
                    .foregroundStyle(selected ? .primary : .secondary)
            }
        }
        .buttonStyle(.plain)
    }

    private func swatchStyle(_ background: FrameStyle.Background) -> AnyShapeStyle {
        switch background {
        case .none:
            return AnyShapeStyle(.black.opacity(0.4))
        case .solid(let color):
            return AnyShapeStyle(Color(
                red: color.red, green: color.green, blue: color.blue))
        case .linearGradient(let top, let bottom):
            return AnyShapeStyle(LinearGradient(
                colors: [
                    Color(red: top.red, green: top.green, blue: top.blue),
                    Color(red: bottom.red, green: bottom.green, blue: bottom.blue),
                ],
                startPoint: .top, endPoint: .bottom))
        case .mesh(let base, _, _):
            // Base layer only — the glows are screen-blended in an overlay
            // (see meshSwatchOverlay), matching the composer's ×0.55
            // darkened base so the swatch predicts the actual render.
            return AnyShapeStyle(Color(
                red: base.red * 0.55, green: base.green * 0.55,
                blue: base.blue * 0.55))
        }
    }

    /// The two radial lights of a mesh background, approximated with the
    /// composer's fractional positions (0.22, 0.78) and (0.82, 0.18).
    @ViewBuilder
    private func meshSwatchOverlay(_ background: FrameStyle.Background) -> some View {
        if case .mesh(_, let glow1, let glow2) = background {
            GeometryReader { proxy in
                let radius = max(proxy.size.width, proxy.size.height) * 0.8
                ZStack {
                    RadialGradient(
                        colors: [
                            Color(
                                red: glow1.red, green: glow1.green,
                                blue: glow1.blue),
                            .clear,
                        ],
                        center: UnitPoint(x: 0.22, y: 0.22),
                        startRadius: 0, endRadius: radius)
                    RadialGradient(
                        colors: [
                            Color(
                                red: glow2.red, green: glow2.green,
                                blue: glow2.blue),
                            .clear,
                        ],
                        center: UnitPoint(x: 0.82, y: 0.82),
                        startRadius: 0, endRadius: radius)
                }
                .blendMode(.screen)
            }
            .clipShape(RoundedRectangle(cornerRadius: 7))
            .allowsHitTesting(false)
        }
    }

    // MARK: Canvas aspect

    private var canvasSection: some View {
        Panel(title: "Canvas", icon: "aspectratio") {
            Picker("Aspect", selection: Binding(
                get: { player.edits.style.canvasAspect ?? 0 },
                set: { newValue in
                    player.updateEdits {
                        $0.style.canvasAspect = newValue == 0 ? nil : newValue
                    }
                })
            ) {
                Text("Auto").tag(0.0)
                Text("16:9").tag(16.0 / 9.0)
                Text("9:16").tag(9.0 / 16.0)
                Text("1:1").tag(1.0)
                Text("4:3").tag(4.0 / 3.0)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
    }

    // MARK: Screen treatment

    private var screenSection: some View {
        Panel(title: "Screen", icon: "macwindow") {
            styleSlider("Padding", systemImage: "arrow.up.left.and.arrow.down.right",
                value: \.padding, range: 0...0.15)
            styleSlider("Corners", systemImage: "button.roundedbottom.horizontal",
                value: \.cornerRadius, range: 0...0.08)
            styleSlider("Shadow", systemImage: "shadow",
                value: \.shadowOpacity, range: 0...1)
        }
    }

    private func styleSlider(
        _ label: String,
        systemImage: String,
        value keyPath: WritableKeyPath<FrameStyle, Double> & Sendable,
        range: ClosedRange<Double>
    ) -> some View {
        HStack(spacing: 8) {
            Label(label, systemImage: systemImage)
                .font(.callout)
                .frame(width: 96, alignment: .leading)
                .labelStyle(.titleOnly)
            Slider(
                value: Binding(
                    get: { player.edits.style[keyPath: keyPath] },
                    set: { newValue in
                        player.updateEdits { $0.style[keyPath: keyPath] = newValue }
                    }),
                in: range)
            Text(String(format: "%.0f", player.edits.style[keyPath: keyPath] / range.upperBound * 100))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 26, alignment: .trailing)
        }
    }

    // MARK: Camera PiP

    private var cameraSection: some View {
        Panel(title: "Camera", icon: "web.camera") {
            Toggle("Show camera", isOn: Binding(
                get: { !player.edits.camera.hidden },
                set: { newValue in player.updateEdits { $0.camera.hidden = !newValue } }))
            if !player.edits.camera.hidden {
                Picker("Position", selection: Binding(
                    get: { player.edits.camera.corner },
                    set: { newValue in player.updateEdits { $0.camera.corner = newValue } })
                ) {
                    Image(systemName: "arrow.up.left").tag(CameraStyle.Corner.topLeft)
                    Image(systemName: "arrow.up.right").tag(CameraStyle.Corner.topRight)
                    Image(systemName: "arrow.down.left").tag(CameraStyle.Corner.bottomLeft)
                    Image(systemName: "arrow.down.right").tag(CameraStyle.Corner.bottomRight)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Picker("Shape", selection: Binding(
                    get: { player.edits.camera.shape },
                    set: { newValue in player.updateEdits { $0.camera.shape = newValue } })
                ) {
                    Text("Rounded").tag(CameraStyle.Shape.rounded)
                    Text("Circle").tag(CameraStyle.Shape.circle)
                    Text("Square").tag(CameraStyle.Shape.square)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                LabeledContent("Intro") {
                    Picker("Intro", selection: Binding(
                        get: { player.edits.camera.introNs },
                        set: { newValue in
                            player.updateEdits(kind: "camera-intro") {
                                $0.camera.introNs = newValue
                            }
                        })
                    ) {
                        Text("Off").tag(Int64(0))
                        Text("3 s").tag(Int64(3_000_000_000))
                        Text("5 s").tag(Int64(5_000_000_000))
                        Text("10 s").tag(Int64(10_000_000_000))
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
                .font(.callout)
                Text("Opens fullscreen on you, then flies into the corner — start the lecture face-first.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                HStack(spacing: 8) {
                    Text("Size")
                        .font(.callout)
                        .frame(width: 96, alignment: .leading)
                    Slider(
                        value: Binding(
                            get: { player.edits.camera.size },
                            set: { newValue in player.updateEdits { $0.camera.size = newValue } }),
                        in: 0.12...0.45)
                    Text(String(format: "%.0f", player.edits.camera.size * 100))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 26, alignment: .trailing)
                }
                Toggle("Mirror", isOn: Binding(
                    get: { player.edits.camera.mirrored },
                    set: { newValue in player.updateEdits { $0.camera.mirrored = newValue } }))
                Toggle("Shrink during zooms", isOn: Binding(
                    get: { player.edits.camera.zoomedScale < 0.999 },
                    set: { newValue in
                        player.updateEdits { $0.camera.zoomedScale = newValue ? 0.7 : 1.0 }
                    }))
            }
        }
        .toggleStyle(.switch)
    }

    // MARK: Cursor

    private var cursorSection: some View {
        Panel(title: "Cursor", icon: "cursorarrow.motionlines") {
            Toggle("Click ripples", isOn: Binding(
                get: { player.edits.cursor.clickRipplesEnabled },
                set: { newValue in
                    player.updateEdits { $0.cursor.clickRipples = newValue }
                }))
            if player.hasKeystrokes {
                Toggle("Shortcut overlay", isOn: Binding(
                    get: { player.edits.cursor.keystrokeOverlayEnabled },
                    set: { newValue in
                        player.updateEdits { $0.cursor.keystrokeOverlay = newValue }
                    }))
                    .help("Shows pressed shortcuts (⌘⇧P) as chips. Only shortcuts render — plain typing never appears.")
            }
            Toggle("Show cursor", isOn: Binding(
                get: { player.edits.cursor.showCursor },
                set: { newValue in player.updateEdits { $0.cursor.showCursor = newValue } }))
            Toggle("Smooth movement", isOn: Binding(
                get: { player.edits.cursor.smoothed },
                set: { newValue in player.updateEdits { $0.cursor.smoothed = newValue } }))
            HStack(spacing: 8) {
                Text("Size")
                    .font(.callout)
                    .frame(width: 96, alignment: .leading)
                Slider(
                    value: Binding(
                        get: { player.edits.cursor.sizeMultiplier },
                        set: { newValue in
                            player.updateEdits { $0.cursor.sizeMultiplier = newValue }
                        }),
                    in: 0.5...3)
                Text(String(format: "%.1f×", player.edits.cursor.sizeMultiplier))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 30, alignment: .trailing)
            }
        }
        .toggleStyle(.switch)
    }

    // MARK: Clips

    @State private var detectionResult: String?

    private var clipsSection: some View {
        Panel(title: "Clips", icon: "scissors") {
            Text("S splits at the playhead · X ripple-deletes · right-click a clip for speed.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button {
                Task {
                    let spans = await player.detectAndSpeedDeadStretches()
                    detectionResult = spans == 0
                        ? "No dead stretches found."
                        : "Sped up \(spans) dead stretch\(spans == 1 ? "" : "es") 4× (⌘Z undoes)."
                }
            } label: {
                Label("Detect dead stretches", systemImage: "hare")
                    .frame(maxWidth: .infinity)
            }
            if let status = player.clipStatus {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else if let detectionResult {
                Text(detectionResult)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text("Idle cursor + quiet audio ≥ 8 s → played at 4× with silent audio. Everything stays editable.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: Audio

    private var audioSection: some View {
        Panel(title: "Audio", icon: "waveform.badge.mic") {
            Toggle("Reduce background noise", isOn: Binding(
                get: { player.edits.micNoiseReduction },
                set: { newValue in player.updateEdits { $0.micNoiseReduction = newValue } }))
            Text("Spectral noise gate on the mic at export — fan hum and hiss drop out, your voice stays. Raw audio is never modified.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .toggleStyle(.switch)
    }

    // MARK: Captions

    private var captionsSection: some View {
        Panel(title: "Captions", icon: "captions.bubble") {
            Button {
                player.transcribe()
            } label: {
                Label(
                    player.isTranscribing ? "Transcribing…" : "Transcribe (on-device)",
                    systemImage: "waveform.and.mic")
                    .frame(maxWidth: .infinity)
            }
            .disabled(player.isTranscribing)
            if let status = player.captionStatus {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if !player.captions.isEmpty {
                HStack {
                    Button("Edit transcript") { showTranscript = true }
                    Button("Export SRT") { exportCaptions(format: .srt) }
                    Button("Export VTT") { exportCaptions(format: .vtt) }
                }
                .font(.callout)
                Text("Cue times follow your cuts and speed changes automatically. Upload the file next to the MP4 on your LMS.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Text("Runs entirely on this Mac (Apple Speech). Nothing is uploaded.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    private func exportCaptions(format: CaptionFormat) {
        // Serialize FIRST: if trims/cuts leave no cues, say so instead of
        // silently writing a 0-byte subtitle file.
        guard let text = player.captionTextForExport(format: format) else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = player.projectURL
            .deletingPathExtension().lastPathComponent + "." + format.rawValue
        panel.directoryURL = FileManager.default
            .urls(for: .moviesDirectory, in: .userDomainMask).first
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            player.loadError = "Caption export failed: \(error.localizedDescription)"
        }
    }

    // MARK: Zooms

    private var zoomSection: some View {
        Panel(title: "Zooms", icon: "plus.magnifyingglass") {
            ForEach(player.edits.zooms) { zoom in
                zoomRow(zoom)
            }
            if player.edits.zooms.isEmpty {
                Text("Record with cursor & clicks enabled, or add one at the playhead.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Button {
                    // The playhead lives on the OUTPUT timeline; zooms are
                    // source-anchored.
                    let start = player.effectiveClipTimeline
                        .sourceTime(forOutput: player.timeNs)
                    let end = min(player.sourceDurationNs, start + 2_500_000_000)
                    guard end > start + ZoomSegment.minLengthNs else { return }
                    let zoom = ZoomSegment(startNs: start, endNs: end, scale: 2.0, origin: "manual")
                    player.updateEdits { edits in
                        edits.zooms.append(zoom)
                        edits.zooms.sort { $0.startNs < $1.startNs }
                    }
                    player.selectedZoomID = zoom.id
                } label: {
                    Label("Add at playhead", systemImage: "plus")
                }
                Spacer()
                Button("Regenerate") { player.regenerateZooms() }
            }
            .font(.callout)
        }
    }

    private func zoomRow(_ zoom: ZoomSegment) -> some View {
        let selected = player.selectedZoomID == zoom.id
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Toggle("", isOn: Binding(
                    get: { zoom.isActive },
                    set: { enabled in
                        player.updateEdits { edits in
                            if let index = edits.zooms.firstIndex(where: { $0.id == zoom.id }) {
                                edits.zooms[index].disabled = enabled ? nil : true
                            }
                        }
                    }))
                .labelsHidden()
                .toggleStyle(.checkbox)
                Text("\(EditorView.timeText(zoom.startNs)) – \(EditorView.timeText(zoom.endNs))")
                    .font(.caption.monospacedDigit())
                Spacer()
                Text(zoom.origin == "generated" ? "auto" : "manual")
                    .font(.caption2)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(.white.opacity(0.1), in: Capsule())
                    .foregroundStyle(.secondary)
                Button {
                    player.updateEdits { edits in
                        edits.zooms.removeAll { $0.id == zoom.id }
                    }
                    if player.selectedZoomID == zoom.id {
                        player.selectedZoomID = nil
                    }
                } label: {
                    Image(systemName: "trash")
                        .font(.caption)
                }
                .buttonStyle(.plain)
            }
            HStack(spacing: 8) {
                Slider(
                    value: Binding(
                        get: { zoom.scale },
                        set: { newValue in
                            player.updateEdits { edits in
                                if let index = edits.zooms.firstIndex(where: { $0.id == zoom.id }) {
                                    edits.zooms[index].scale = newValue
                                }
                            }
                        }),
                    in: 1.0...4.5)
                Text(String(format: "%.1f×", zoom.scale))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 30, alignment: .trailing)
            }
        }
        .padding(8)
        .background(
            selected ? Color.accentColor.opacity(0.12) : .white.opacity(0.03),
            in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(selected ? Color.accentColor.opacity(0.6) : .clear))
        .contentShape(Rectangle())
        .onTapGesture {
            player.selectedZoomID = selected ? nil : zoom.id
        }
    }

    // MARK: Trim

    private var trimSection: some View {
        Panel(title: "Trim", icon: "timeline.selection") {
            HStack {
                Button("Set start") {
                    let time = player.timeNs
                    player.updateEdits { $0.trimStartNs = time }
                }
                Button("Set end") {
                    let time = player.timeNs
                    player.updateEdits { $0.trimEndNs = time }
                }
                Spacer()
                Button("Clear") {
                    player.updateEdits {
                        $0.trimStartNs = nil
                        $0.trimEndNs = nil
                    }
                }
            }
            .font(.callout)
            if player.edits.trimStartNs != nil || player.edits.trimEndNs != nil {
                Text("Range \(EditorView.timeText(player.edits.trimStartNs ?? 0)) – "
                    + EditorView.timeText(player.edits.trimEndNs ?? player.durationNs))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Style presets

    private var presetSection: some View {
        Panel(title: "Style presets", icon: "square.stack.3d.up") {
            if !presetStore.presets.isEmpty {
                ForEach(presetStore.presets) { preset in
                    HStack {
                        Button {
                            player.updateEdits { edits in
                                edits.style = preset.style
                                edits.cursor = preset.cursor
                                edits.camera = preset.camera
                            }
                        } label: {
                            Label(preset.name, systemImage: "paintbrush")
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                        Button {
                            presetStore.remove(named: preset.name)
                        } label: {
                            Image(systemName: "trash")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                    .font(.callout)
                }
                Divider().overlay(.white.opacity(0.1))
            }
            HStack {
                TextField("Preset name (e.g. CS 203)", text: $newPresetName)
                    .textFieldStyle(.roundedBorder)
                Button("Save look") {
                    let name = newPresetName.trimmingCharacters(in: .whitespaces)
                    guard !name.isEmpty else { return }
                    presetStore.save(StylePreset(
                        name: name,
                        style: player.edits.style,
                        cursor: player.edits.cursor,
                        camera: player.edits.camera))
                    newPresetName = ""
                }
                .disabled(newPresetName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .font(.callout)
        }
    }

    // MARK: Export

    @State private var exportPreset: PreviewPlayer.ExportPreset = .studio

    private var exportSection: some View {
        Panel(title: "Export", icon: "square.and.arrow.up") {
            switch player.exportState {
            case .idle, .done, .failed:
                Picker("Preset", selection: $exportPreset) {
                    ForEach(PreviewPlayer.ExportPreset.allCases) { preset in
                        Text(preset.label).tag(preset)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Text(exportPreset.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("Resumable (safe for long lectures)", isOn: $resumableExport)
                    .font(.callout)
                    .help("Renders in checkpointed segments inside the project. If the export is interrupted, exporting again resumes instead of starting over.")
                HStack {
                    Button {
                        runExport(styled: true)
                    } label: {
                        Label("Styled MP4", systemImage: "sparkles.tv")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    Button("Raw") { runExport(styled: false) }
                    Button("GIF") { runGIFExport() }
                        .help("Looping animated GIF (max 540p) with all styling and cuts")
                }
                if case .done(let url) = player.exportState {
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    } label: {
                        Label("Show in Finder", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                    .buttonStyle(.plain)
                    .font(.callout)
                }
                if case .failed(let message) = player.exportState {
                    Text(message).font(.caption).foregroundStyle(.red)
                }
            case .running(let stage, let fraction):
                HStack {
                    ProgressView(value: fraction) {
                        Text("Exporting (\(stage))…").font(.callout)
                    }
                    Button("Cancel") { player.cancelExport() }
                        .font(.callout)
                }
            }
        }
    }

    private func runGIFExport() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = player.projectURL
            .deletingPathExtension().lastPathComponent + ".gif"
        panel.directoryURL = FileManager.default
            .urls(for: .moviesDirectory, in: .userDomainMask).first
        guard panel.runModal() == .OK, let url = panel.url else { return }
        player.exportGIF(to: url)
    }

    private func runExport(styled: Bool) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = player.projectURL
            .deletingPathExtension().lastPathComponent + (styled ? " styled.mp4" : ".mp4")
        panel.directoryURL = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first
        guard panel.runModal() == .OK, let url = panel.url else { return }
        player.export(
            to: url, styled: styled,
            height: styled ? exportPreset.height : nil,
            bitsPerPixelPerFrame: exportPreset.bitsPerPixelPerFrame,
            checkpointed: styled && resumableExport)
    }
}
