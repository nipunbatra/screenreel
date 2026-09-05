import CaptureCore
import SwiftUI

// MARK: - Shared chrome

/// Section container used across the start screen and inspector.
struct Panel<Content: View>: View {
    var title: String?
    var icon: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title {
                HStack(spacing: 6) {
                    if let icon {
                        Image(systemName: icon)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Text(title.uppercased())
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .kerning(0.6)
                }
            }
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(.white.opacity(0.07)))
    }
}

extension Color {
    static let editorBackdrop = Color(red: 0.09, green: 0.09, blue: 0.11)
    static let canvasBackdrop = Color(red: 0.06, green: 0.06, blue: 0.075)
}

// MARK: - Start screen

struct StartView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                ScrollView(showsIndicators: false) {
                    recorderPane
                        .padding(20)
                }
                recordFooter
                    .padding(.horizontal, 20)
                    .padding(.bottom, 16)
            }
            .frame(width: 384)
            Divider().overlay(.white.opacity(0.08))
            projectsPane
                .padding(20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.editorBackdrop)
    }

    /// Record button + disk line, pinned under the scrolling settings so
    /// they are always reachable.
    private var recordFooter: some View {
        VStack(spacing: 8) {
            if !model.displays.isEmpty {
                Button {
                    model.startCountdown()
                } label: {
                    Label("Start Recording", systemImage: "record.circle.fill")
                        .font(.title3.bold())
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .keyboardShortcut("r")
                let hotkey = model.preferences.hotkey(for: .toggleRecording)
                if hotkey != .off {
                    Text("\(hotkey.label) from any app · or the menu bar")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Label(model.diskSummary, systemImage: "internaldrive")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var recorderPane: some View {
        @Bindable var model = model
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 9)
                        .fill(LinearGradient(
                            colors: [Color(red: 0.85, green: 0.25, blue: 0.22),
                                     Color(red: 0.55, green: 0.10, blue: 0.14)],
                            startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(width: 38, height: 38)
                    Image(systemName: "record.circle")
                        .font(.title3.bold())
                        .foregroundStyle(.white)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(Branding.displayName)
                        .font(.title2.bold())
                    Text(Branding.tagline)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.bottom, 6)

            if model.displays.isEmpty {
                Panel(title: "Screen Recording permission", icon: "lock.shield") {
                    Text(model.screenPermission.guidance.isEmpty
                        ? "\(Branding.displayName) needs Screen Recording permission to see your displays."
                        : model.screenPermission.guidance)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    HStack {
                        Button {
                            switch model.screenPermission {
                            case .denied, .granted:
                                model.requestScreenRecording()
                            case .staleGrant:
                                model.repairScreenRecording()
                            case .grantedAfterLaunch:
                                model.relaunch()
                            }
                        } label: {
                            Label(
                                model.screenPermission.actionTitle.isEmpty
                                    ? "Grant Permission" : model.screenPermission.actionTitle,
                                systemImage: model.screenPermission == .grantedAfterLaunch
                                    ? "arrow.clockwise.circle.fill" : "hand.raised")
                        }
                        .buttonStyle(.borderedProminent)
                        Button("Open System Settings") {
                            model.openScreenRecordingSettings()
                        }
                    }
                    if model.needsRelaunch, model.screenPermission != .grantedAfterLaunch {
                        Button {
                            model.relaunch()
                        } label: {
                            Label("Relaunch \(Branding.displayName)", systemImage: "arrow.clockwise")
                        }
                    }
                    if let message = model.statusMessage {
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
            } else {
                Panel(title: "Source", icon: "display") {
                    Picker("Kind", selection: $model.sourceKind) {
                        Label("Screen", systemImage: "display").tag(CaptureSourceKind.display)
                        Label("Window", systemImage: "macwindow").tag(CaptureSourceKind.window)
                        Label("Area", systemImage: "rectangle.dashed").tag(CaptureSourceKind.area)
                        Label("App", systemImage: "square.grid.2x2").tag(CaptureSourceKind.application)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .onChange(of: model.sourceKind) { model.refreshSources() }

                    if model.displays.count > 1 {
                        DisplayCardStrip()
                    }

                    sourceDetail

                    SourcePreviewBox()
                    if !model.captureSummary.isEmpty {
                        Text(model.captureSummary)
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }

                    HStack(spacing: 10) {
                        Picker("Frame rate", selection: $model.frameRate) {
                            Text("30 fps").tag(30.0)
                            Text("60 fps").tag(60.0)
                        }
                        .pickerStyle(.segmented)
                        Picker("Quality", selection: $model.captureQuality) {
                            Text("Retina").tag(AppModel.CaptureQuality.native)
                            Text("1×").tag(AppModel.CaptureQuality.standard)
                        }
                        .pickerStyle(.segmented)
                        .help("Retina records native pixels (crisp, heavier). 1× halves the resolution — much lighter while the machine is busy.")
                    }
                    .labelsHidden()
                }
                Panel(title: "Camera", icon: "web.camera") {
                    Toggle("Record webcam", isOn: Binding(
                        get: { model.cameraEnabled },
                        set: { model.setCameraEnabled($0) }))
                    if model.cameraEnabled {
                        if model.cameras.isEmpty {
                            Text("No camera found.")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        } else {
                            Picker("Camera", selection: $model.selectedCameraID) {
                                ForEach(model.cameras) { camera in
                                    Text(camera.name).tag(Optional(camera.uniqueID))
                                }
                            }
                            .labelsHidden()
                        }
                        if let session = model.previewCameraSession {
                            CameraPreviewView(session: session)
                                .frame(height: 130)
                                .frame(maxWidth: .infinity)
                                .clipShape(RoundedRectangle(cornerRadius: 9))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 9)
                                        .strokeBorder(.white.opacity(0.1)))
                        }
                        Text("Recorded as its own track — position, size, and shape stay editable after recording.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)
                Panel(title: "Audio & input", icon: "waveform") {
                    Toggle("Microphone", isOn: $model.microphoneEnabled)
                    if model.microphoneEnabled {
                        MicLevelBar(level: model.micMonitor.level, active: model.micMonitor.active)
                    }
                    Toggle("System audio", isOn: $model.systemAudioEnabled)
                    Toggle("Cursor & clicks (auto-zoom)", isOn: $model.captureEvents)
                    if model.captureEvents {
                        Toggle("Keystrokes (shortcut overlay)", isOn: $model.captureKeystrokes)
                            .help("Records key presses so the editor can show shortcut chips like ⌘⇧P. Off by default — keystrokes can include passwords you type while recording.")
                    }
                    if model.captureEvents && !model.hasInputMonitoring {
                        HStack(spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                            Text("Needs Input Monitoring permission")
                                .font(.caption)
                                .foregroundStyle(.orange)
                            Button("Grant") {
                                model.requestInputMonitoring()
                            }
                            .font(.caption)
                            .help("Registers Screenreel with macOS and shows the system prompt (or opens System Settings with the app already in the list).")
                        }
                    }
                }
                .toggleStyle(.switch)
            }

            if let message = model.statusMessage, !model.displays.isEmpty {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.orange)
                HStack {
                    if model.screenPermission == .staleGrant {
                        Button {
                            model.repairScreenRecording()
                        } label: {
                            Label("Repair Permission", systemImage: "wrench.and.screwdriver")
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    if model.needsRelaunch {
                        Button {
                            model.relaunch()
                        } label: {
                            Label("Relaunch \(Branding.displayName)", systemImage: "arrow.clockwise.circle.fill")
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
            }
            Spacer()
        }
        .onAppear {
            model.refreshSources()
            model.startSourcePreviews()
            if model.microphoneEnabled { model.micMonitor.start() }
        }
        .onDisappear {
            model.micMonitor.stop()
            model.stopSourcePreviews()
        }
        .onChange(of: model.microphoneEnabled) { _, enabled in
            enabled ? model.micMonitor.start() : model.micMonitor.stop()
        }
        .onChange(of: model.selectedDisplayID) { Task { await model.refreshSourcePreviewOnce() } }
        .onChange(of: model.selectedWindowID) { Task { await model.refreshSourcePreviewOnce() } }
        .onChange(of: model.selectedAppBundleID) { Task { await model.refreshSourcePreviewOnce() } }
        .onChange(of: model.sourceKind) { Task { await model.refreshSourcePreviewOnce() } }
        .onChange(of: model.cameraEnabled) { model.refreshCameraPreviewSession() }
        .onChange(of: model.selectedCameraID) { model.refreshCameraPreviewSession() }
    }

    /// Per-kind source controls under the display picker.
    @ViewBuilder private var sourceDetail: some View {
        @Bindable var model = model
        switch model.sourceKind {
        case .display:
            EmptyView()
        case .window:
            if model.windows.isEmpty {
                Text("No capturable windows found.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else {
                WindowThumbnailGrid()
            }
        case .area:
            Button {
                model.presentAreaPicker(thenRecord: false)
            } label: {
                Label("Select on Screen…", systemImage: "viewfinder")
                    .frame(maxWidth: .infinity)
            }
            .help("Drag the area on the actual screen. \(model.preferences.hotkey(for: .recordArea).label) does the same from any app and records right away.")
            HStack(spacing: 6) {
                areaField("X", $model.areaX)
                areaField("Y", $model.areaY)
                areaField("W", $model.areaWidth)
                areaField("H", $model.areaHeight)
            }
            HStack(spacing: 6) {
                Button("720p") { model.centerArea(width: 1280, height: 720) }
                Button("1080p") { model.centerArea(width: 1920, height: 1080) }
                Button("Square") { model.centerArea(width: 1080, height: 1080) }
            }
            .font(.caption)
            .controlSize(.small)
            Text("Points on the selected display, top-left origin.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        case .application:
            if model.apps.isEmpty {
                Text("No running applications found.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else {
                AppIconGrid()
            }
        }
    }

    private func areaField(_ label: String, _ value: Binding<Double>) -> some View {
        HStack(spacing: 3) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            TextField(label, value: value, format: .number.precision(.fractionLength(0)))
                .textFieldStyle(.roundedBorder)
                .frame(width: 56)
        }
    }

    private var projectsPane: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Text("Recordings")
                    .font(.title2.bold())
                if !model.projectCards.isEmpty {
                    Text("\(model.projectCards.count)")
                        .font(.caption.monospacedDigit().weight(.semibold))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(.white.opacity(0.1), in: Capsule())
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    model.revealProject(at: model.recordingsDirectory)
                } label: {
                    Label("Show in Finder", systemImage: "folder")
                }
                Button {
                    model.openProjectPanel()
                } label: {
                    Label("Open…", systemImage: "square.and.arrow.down")
                }
                .keyboardShortcut("o")
            }
            if model.projectCards.isEmpty {
                Spacer()
                ContentUnavailableView(
                    "No recordings yet",
                    systemImage: "film.stack",
                    description: Text("Recordings land in ~/Movies/\(Branding.displayName) as recoverable .aks packages."))
                Spacer()
            } else {
                ScrollView {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 220, maximum: 300), spacing: 14)],
                        spacing: 14
                    ) {
                        ForEach(model.projectCards) { card in
                            ProjectCardView(card: card) {
                                model.openProject(at: card.url)
                            }
                            .contextMenu {
                                Button("Open in Editor") { model.openProject(at: card.url) }
                                Button("Show in Finder") { model.revealProject(at: card.url) }
                                Divider()
                                Button("Move to Trash", role: .destructive) {
                                    model.trashProject(at: card.url)
                                }
                            }
                        }
                    }
                    .padding(.bottom, 12)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// Click-a-thumbnail display cards (multi-monitor setups).
struct DisplayCardStrip: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(model.displays, id: \.displayID) { display in
                    let selected = model.selectedDisplayID == display.displayID
                    Button {
                        model.selectedDisplayID = display.displayID
                        Task { await model.refreshSourcePreviewOnce() }
                    } label: {
                        VStack(spacing: 4) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 7)
                                    .fill(Color.canvasBackdrop)
                                if let thumb = model.displayThumbnails[display.displayID] {
                                    Image(decorative: thumb, scale: 1)
                                        .resizable()
                                        .aspectRatio(contentMode: .fill)
                                }
                            }
                            .frame(width: 132, height: 76)
                            .clipShape(RoundedRectangle(cornerRadius: 7))
                            .overlay(
                                RoundedRectangle(cornerRadius: 7)
                                    .strokeBorder(
                                        selected ? Color.accentColor : .white.opacity(0.12),
                                        lineWidth: selected ? 2 : 1))
                            Text("\(display.widthPx)×\(display.heightPx)")
                                .font(.caption2)
                                .foregroundStyle(selected ? .primary : .secondary)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

/// Click-a-thumbnail window picker (visual grid, not a dropdown).
struct WindowThumbnailGrid: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 150, maximum: 200), spacing: 8)],
                spacing: 8
            ) {
                ForEach(model.windows) { window in
                    let selected = model.selectedWindowID == window.windowID
                    Button {
                        model.selectedWindowID = window.windowID
                        Task { await model.refreshSourcePreviewOnce() }
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 7)
                                    .fill(Color.canvasBackdrop)
                                if let thumb = model.windowThumbnails[window.windowID] {
                                    Image(decorative: thumb, scale: 1)
                                        .resizable()
                                        .aspectRatio(contentMode: .fit)
                                        .padding(3)
                                } else {
                                    Image(systemName: "macwindow")
                                        .foregroundStyle(.tertiary)
                                }
                            }
                            .frame(height: 84)
                            .frame(maxWidth: .infinity)
                            .clipShape(RoundedRectangle(cornerRadius: 7))
                            .overlay(
                                RoundedRectangle(cornerRadius: 7)
                                    .strokeBorder(
                                        selected ? Color.accentColor : .white.opacity(0.12),
                                        lineWidth: selected ? 2 : 1))
                            Text(window.appName)
                                .font(.caption2.weight(.medium))
                                .lineLimit(1)
                            Text(window.title)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .frame(maxHeight: 236)
    }
}

/// Running-application picker with real app icons.
struct AppIconGrid: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 72, maximum: 96), spacing: 6)],
                spacing: 6
            ) {
                ForEach(model.apps) { app in
                    let selected = model.selectedAppBundleID == app.bundleID
                    Button {
                        model.selectedAppBundleID = app.bundleID
                        Task { await model.refreshSourcePreviewOnce() }
                    } label: {
                        VStack(spacing: 3) {
                            Group {
                                if let icon = model.appIcons[app.bundleID] {
                                    Image(nsImage: icon)
                                        .resizable()
                                } else {
                                    Image(systemName: "app.dashed")
                                        .resizable()
                                        .foregroundStyle(.tertiary)
                                        .padding(8)
                                }
                            }
                            .frame(width: 40, height: 40)
                            Text(app.name)
                                .font(.caption2)
                                .lineLimit(1)
                                .foregroundStyle(selected ? .primary : .secondary)
                        }
                        .padding(6)
                        .frame(maxWidth: .infinity)
                        .background(
                            selected ? Color.accentColor.opacity(0.22) : .white.opacity(0.03),
                            in: RoundedRectangle(cornerRadius: 8))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .strokeBorder(
                                    selected ? Color.accentColor : .clear))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .frame(maxHeight: 210)
    }
}

/// Live "what will I record" thumbnail. For area capture the selection is
/// drawn on top and draggable: drag inside to move, drag the corner dot to
/// resize; the numeric fields stay in sync.
struct SourcePreviewBox: View {
    @Environment(AppModel.self) private var model
    @State private var dragStart: (x: Double, y: Double)?
    @State private var resizeStart: (w: Double, h: Double)?

    var body: some View {
        Group {
            if let preview = model.sourcePreview {
                GeometryReader { proxy in
                    previewBody(preview: preview, viewSize: proxy.size)
                }
                .aspectRatio(
                    Double(model.sourcePreview?.width ?? 16)
                        / Double(max(1, model.sourcePreview?.height ?? 9)),
                    contentMode: .fit)
            } else {
                RoundedRectangle(cornerRadius: 9)
                    .fill(.white.opacity(0.04))
                    .frame(height: 110)
                    .overlay {
                        Label("Preview loads once permission is granted", systemImage: "eye")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
            }
        }
    }

    @ViewBuilder
    private func previewBody(preview: CGImage, viewSize: CGSize) -> some View {
        let display = model.displays.first { $0.displayID == model.selectedDisplayID }
        let pointsWide = Double(display?.widthPoints ?? 1)
        let pointsHigh = Double(display?.heightPoints ?? 1)
        let sx = viewSize.width / pointsWide
        let sy = viewSize.height / pointsHigh

        ZStack(alignment: .topLeading) {
            Image(decorative: preview, scale: 1)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: viewSize.width, height: viewSize.height)
                .clipShape(RoundedRectangle(cornerRadius: 9))
                .overlay(
                    RoundedRectangle(cornerRadius: 9)
                        .strokeBorder(.white.opacity(0.1)))

            if model.sourceKind == .area {
                let rect = CGRect(
                    x: model.areaX * sx, y: model.areaY * sy,
                    width: model.areaWidth * sx, height: model.areaHeight * sy)
                // Dim everything outside the selection.
                Path { path in
                    path.addRect(CGRect(origin: .zero, size: viewSize))
                    path.addRect(rect)
                }
                .fill(.black.opacity(0.55), style: FillStyle(eoFill: true))
                .allowsHitTesting(false)

                Rectangle()
                    .strokeBorder(Color.accentColor, lineWidth: 1.5)
                    .background(Color.white.opacity(0.001))
                    .frame(width: rect.width, height: rect.height)
                    .offset(x: rect.minX, y: rect.minY)
                    .gesture(
                        DragGesture()
                            .onChanged { value in
                                if dragStart == nil {
                                    dragStart = (model.areaX, model.areaY)
                                }
                                guard let start = dragStart else { return }
                                let maxX = pointsWide - model.areaWidth
                                let maxY = pointsHigh - model.areaHeight
                                model.areaX = min(max(0, start.x + value.translation.width / sx), max(0, maxX))
                                model.areaY = min(max(0, start.y + value.translation.height / sy), max(0, maxY))
                            }
                            .onEnded { _ in dragStart = nil })

                // Corner resize handle.
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 11, height: 11)
                    .offset(x: rect.maxX - 5.5, y: rect.maxY - 5.5)
                    .gesture(
                        DragGesture()
                            .onChanged { value in
                                if resizeStart == nil {
                                    resizeStart = (model.areaWidth, model.areaHeight)
                                }
                                guard let start = resizeStart else { return }
                                model.areaWidth = min(
                                    max(64, start.w + value.translation.width / sx),
                                    pointsWide - model.areaX)
                                model.areaHeight = min(
                                    max(64, start.h + value.translation.height / sy),
                                    pointsHigh - model.areaY)
                            }
                            .onEnded { _ in resizeStart = nil })
            }
        }
    }
}

/// Live input level so a dead microphone is obvious before recording.
struct MicLevelBar: View {
    let level: Double
    let active: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "mic.fill")
                .font(.caption)
                .foregroundStyle(active ? Color.green : Color.secondary)
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.08))
                    Capsule()
                        .fill(level > 0.85 ? Color.orange : Color.green)
                        .frame(width: max(3, proxy.size.width * level))
                        .animation(.linear(duration: 0.08), value: level)
                }
            }
            .frame(height: 6)
        }
    }
}

struct ProjectCardView: View {
    let card: AppModel.ProjectCard
    let open: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 9)
                        .fill(Color.canvasBackdrop)
                    if let thumbnail = card.thumbnail {
                        Image(decorative: thumbnail, scale: 1)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    } else {
                        Image(systemName: "film")
                            .font(.title)
                            .foregroundStyle(.tertiary)
                    }
                }
                .aspectRatio(16 / 9, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 9))
                .overlay(alignment: .bottomTrailing) {
                    if let durationNs = card.durationNs {
                        Text(Self.durationText(durationNs))
                            .font(.caption2.monospacedDigit().weight(.medium))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.black.opacity(0.65), in: Capsule())
                            .padding(6)
                    }
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(card.name)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                    Text(card.modified, format: .relative(presentation: .named))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(8)
            .background(
                .white.opacity(hovering ? 0.08 : 0.04),
                in: RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(.white.opacity(hovering ? 0.16 : 0.07)))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }

    static func durationText(_ ns: Int64) -> String {
        let seconds = Int(Double(ns) / 1e9)
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

// MARK: - Countdown

struct CountdownView: View {
    @Environment(AppModel.self) private var model
    let remaining: Int

    var body: some View {
        VStack(spacing: 12) {
            Text("\(remaining)")
                .font(.system(size: 150, weight: .bold, design: .rounded))
                .contentTransition(.numericText(countsDown: true))
                .foregroundStyle(.red)
            Text("Click to start now · esc to cancel")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.editorBackdrop)
        .contentShape(Rectangle())
        .onTapGesture { model.skipCountdown() }
        .focusable()
        .onKeyPress(.escape) {
            model.cancelCountdown()
            return .handled
        }
        .onExitCommand { model.cancelCountdown() }
    }
}

// MARK: - Recording HUD

struct RecordingHUDView: View {
    @Environment(AppModel.self) private var model
    @State private var pulse = false
    @State private var tick = Date()
    private let timer = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 14) {
            HStack(spacing: 10) {
                Circle()
                    .fill(model.isPaused ? Color.orange : .red)
                    .frame(width: 13, height: 13)
                    .opacity(pulse && !model.isPaused ? 0.35 : 1)
                    .animation(
                        model.isPaused ? nil : .easeInOut(duration: 0.8).repeatForever(),
                        value: pulse)
                Text(model.isPaused ? "Paused" : "Recording")
                    .font(.title3.bold())
                Text(model.elapsedText)
                    .font(.title3.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .id(tick)
            }
            HStack(spacing: 10) {
                Button {
                    model.togglePause()
                } label: {
                    Label(
                        model.isPaused ? "Resume" : "Pause",
                        systemImage: model.isPaused ? "play.circle" : "pause.circle")
                        .frame(maxWidth: 110)
                        .padding(.vertical, 4)
                }
                Button {
                    model.stopRecording()
                } label: {
                    Label("Stop", systemImage: "stop.circle.fill")
                        .font(.title3.bold())
                        .frame(maxWidth: 140)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
            }
            Text("This window is excluded from the capture.")
                .font(.caption)
                .foregroundStyle(.tertiary)

            if !model.warnings.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(model.warnings, id: \.self) { warning in
                            Label(warning, systemImage: "exclamationmark.triangle")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }
                }
                .frame(maxHeight: 110)
            }
        }
        .padding(26)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.editorBackdrop)
        .onAppear { pulse = true }
        .onReceive(timer) { now in tick = now }
    }
}
