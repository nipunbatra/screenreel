import AppKit
import AppSupport
import AVFoundation
import CaptureCore
import CoreGraphics
import EventCapture
import Foundation
import Observation
import PreviewEngine
import ProjectModel
import SwiftUI

/// Top-level app state: start screen → countdown → recording → editor.
@Observable
@MainActor
final class AppModel {
    enum Mode {
        case start
        case countdown(Int)
        case recording
        case editor(PreviewPlayer)
    }

    var mode: Mode = .start

    // MARK: Recorder configuration

    var displays: [SCKCapture.DisplayInfo] = []
    var selectedDisplayID: UInt32?
    var sourceKind: CaptureSourceKind = .display
    var windows: [SCKCapture.WindowInfo] = []
    var selectedWindowID: UInt32?
    var apps: [SCKCapture.AppInfo] = []
    var selectedAppBundleID: String?
    /// Area selection in display points (top-left origin, display-local).
    var areaX: Double = 0
    var areaY: Double = 0
    var areaWidth: Double = 1280
    var areaHeight: Double = 720
    var cameraEnabled = false
    var cameras: [CameraCapture.CameraInfo] = []
    var selectedCameraID: String?
    var microphoneEnabled = true
    var systemAudioEnabled = false
    var captureEvents = true
    /// Shortcut-overlay keystroke capture: OFF by default (keystrokes can
    /// spell out passwords); per-recording opt-in.
    var captureKeystrokes = false
    var frameRate: Double = 30
    /// Native records true Retina pixels (crisp, 4× the encode work);
    /// standard records at 1× points — much lighter on a busy machine.
    enum CaptureQuality: String, CaseIterable { case native, standard }
    var captureQuality: CaptureQuality = .native
    var statusMessage: String?
    var warnings: [String] = []
    let micMonitor = MicLevelMonitor()
    let hudPanel = RecordingHUDPanelController()
    let countdownPanel = CountdownPanelController()
    let areaPicker = AreaPickerController()
    let menuBar = MenuBarController()
    /// User settings. Mutate through `updatePreferences` so every change
    /// persists and re-registers the global hotkeys.
    private(set) var preferences = Preferences()
    private let preferencesStore = PreferencesStore()
    /// True for AKS_AUTOPILOT_DIR harness launches: no global hotkeys, no
    /// menu-bar item, a one-second countdown, no mic/camera — nothing that
    /// could grab the user's keyboard, pop a permission dialog, or sit on
    /// their screen longer than the flow needs.
    let isHarnessRun = ProcessInfo.processInfo.environment["AKS_AUTOPILOT_DIR"] != nil
    /// SwiftUI's openWindow/openSettings actions, captured by ContentView
    /// so the menu bar and hotkeys can bring windows back after the user
    /// closed them.
    @ObservationIgnored var openMainWindowAction: (@MainActor () -> Void)?
    @ObservationIgnored var openSettingsAction: (@MainActor () -> Void)?
    /// The recording camera's live session (pill self-view).
    var activeCameraSession: AVCaptureSession?
    /// Start-screen camera preview (its own lightweight session).
    private(set) var previewCameraSession: AVCaptureSession?
    /// Live snapshot of what the current source selection will record.
    var sourcePreview: CGImage?
    /// Thumbnails for the visual picker cards.
    var displayThumbnails: [UInt32: CGImage] = [:]
    var windowThumbnails: [UInt32: CGImage] = [:]
    var appIcons: [String: NSImage] = [:]
    private var sourcePreviewTask: Task<Void, Never>?
    private var thumbnailFetchTask: Task<Void, Never>?

    // MARK: Recording state

    private var coordinator: RecordingCoordinator?
    private(set) var recordingStartedAt: Date?
    private(set) var recordingURL: URL?
    private(set) var isPaused = false
    private var pausedAt: Date?
    private var totalPausedSeconds: TimeInterval = 0
    var elapsedText: String {
        guard let recordingStartedAt else { return "0:00" }
        let pausedNow = pausedAt.map { Date().timeIntervalSince($0) } ?? 0
        let seconds = max(0, Int(
            Date().timeIntervalSince(recordingStartedAt) - totalPausedSeconds - pausedNow))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    var recentProjects: [URL] = []
    var autopilotStarted = false
    var uxSelfTestStarted = false
    var needsRelaunch = false
    var screenPermission: ScreenPermissionState = .denied

    /// Quit and reopen this app (permissions like Screen Recording only
    /// apply at launch). A detached shell waits for this process to fully
    /// exit before opening the new instance — launching while the old one
    /// is alive gave the fresh instance the old TCC attribution.
    func relaunch() {
        let path = Bundle.main.bundlePath
        let pid = ProcessInfo.processInfo.processIdentifier
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [
            "-c",
            "while /bin/kill -0 \(pid) 2>/dev/null; do /bin/sleep 0.1; done; /usr/bin/open \"\(path)\"",
        ]
        try? process.run()
        NSApplication.shared.terminate(nil)
    }

    struct ProjectCard: Identifiable {
        let url: URL
        var id: URL { url }
        var name: String { url.deletingPathExtension().lastPathComponent }
        var modified: Date
        var durationNs: Int64?
        var thumbnail: CGImage?
    }
    var projectCards: [ProjectCard] = []

    init() {
        preferences = preferencesStore.load()
        // Harness launches (AKS_AUTOPILOT_DIR) must never pop a system
        // permission dialog on the user's screen: leave the microphone
        // meter and camera off so no AVFoundation access request fires.
        if isHarnessRun {
            microphoneEnabled = false
            cameraEnabled = false
        }
        refreshDisplays()
        refreshRecents()
        startActivationRefresh()
        // This init runs while SwiftUI is still constructing the App value —
        // before NSApplication (and its window-server connection) exists.
        // A status item or a Carbon event target created here asserts
        // inside CoreGraphics; install both once the app has launched.
        NotificationCenter.default.addObserver(
            forName: NSApplication.didFinishLaunchingNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.installMenuBarAndHotkeys()
            }
        }
    }

    @ObservationIgnored private var menuBarAndHotkeysInstalled = false

    /// Status item + global hotkeys. Idempotent; called from the
    /// did-finish-launching notification and, as a fallback, from the
    /// main window's onAppear. Harness runs get neither.
    func installMenuBarAndHotkeys() {
        guard !isHarnessRun, !menuBarAndHotkeysInstalled else { return }
        menuBarAndHotkeysInstalled = true
        menuBar.bind(model: self)
        HotkeyCenter.shared.setHandler { [weak self] action in
            self?.handleHotkey(action)
        }
        HotkeyCenter.shared.apply(preferences)
    }

    // MARK: - Environment

    static var defaultRecordingsDirectory: URL {
        FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Aks")
    }

    /// The folder new recordings land in: the user's choice from Settings
    /// while it exists, else ~/Movies/Aks (created on demand).
    var recordingsDirectory: URL {
        if let path = preferences.recordingsFolderPath {
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
                isDirectory.boolValue
            {
                return URL(fileURLWithPath: path, isDirectory: true)
            }
        }
        let url = Self.defaultRecordingsDirectory
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    var recordingsDirectoryDisplayPath: String {
        (recordingsDirectory.path as NSString).abbreviatingWithTildeInPath
    }

    // MARK: - Preferences

    func updatePreferences(_ transform: (inout Preferences) -> Void) {
        var updated = preferences
        transform(&updated)
        updated = updated.sanitized()
        guard updated != preferences else { return }
        preferences = updated
        preferencesStore.save(updated)
        if !isHarnessRun {
            HotkeyCenter.shared.apply(updated)
        }
    }

    func setHotkey(_ preset: HotkeyPreset, for action: HotkeyAction) {
        updatePreferences { $0.assign(preset, to: action) }
    }

    /// Chords the OS refused to register, for the Settings window.
    var hotkeyFailures: [HotkeyAction: OSStatus] {
        isHarnessRun ? [:] : HotkeyCenter.shared.failures
    }

    func chooseRecordingsFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = recordingsDirectory
        panel.prompt = "Use This Folder"
        panel.message = "Choose where new recordings are saved"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        updatePreferences { $0.recordingsFolderPath = url.path }
        refreshRecents()
    }

    func resetRecordingsFolder() {
        updatePreferences { $0.recordingsFolderPath = nil }
        refreshRecents()
    }

    // MARK: - Windows

    /// The document window (not the Settings window, not our panels).
    private func isMainWindow(_ window: NSWindow) -> Bool {
        !(window is NSPanel) && window.styleMask.contains(.titled)
            && (window.identifier?.rawValue.hasPrefix("main") == true
                || window.title == Branding.displayName)
    }

    var isMainWindowVisible: Bool {
        NSApplication.shared.windows.contains { isMainWindow($0) && $0.isVisible }
    }

    func hideMainWindow() {
        for window in NSApplication.shared.windows where isMainWindow(window) && window.isVisible {
            window.orderOut(nil)
        }
    }

    /// Bring the main window forward, recreating it if the user closed it.
    func showMainWindow() {
        if let window = NSApplication.shared.windows.first(where: { isMainWindow($0) }) {
            window.makeKeyAndOrderFront(nil)
        } else {
            openMainWindowAction?()
        }
        NSApplication.shared.activate()
    }

    func openSettings() {
        if let openSettingsAction {
            openSettingsAction()
        } else {
            NSApplication.shared.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        }
        NSApplication.shared.activate()
    }

    // MARK: - Menu bar, hotkeys, area picker

    func handleHotkey(_ action: HotkeyAction) {
        switch action {
        case .toggleRecording:
            switch mode {
            case .recording: stopRecording()
            case .countdown: skipCountdown()
            case .start, .editor:
                if areaPicker.isPresenting { return }
                startCountdown()
            }
        case .togglePause:
            if case .recording = mode { togglePause() }
        case .recordArea:
            if areaPicker.isPresenting {
                areaPicker.cancel()
                return
            }
            presentAreaPicker(thenRecord: true)
        }
    }

    /// Show the on-screen area picker. With `thenRecord` the strip's button
    /// says Record and a confirmed selection starts the countdown; without
    /// it (the start screen's "Select on Screen…") the selection only
    /// fills the area fields.
    func presentAreaPicker(thenRecord: Bool) {
        guard !areaPicker.isPresenting else { return }
        switch mode {
        case .countdown, .recording: return
        case .start, .editor: break
        }
        guard !displays.isEmpty else {
            statusMessage = "\(Branding.displayName) needs Screen Recording permission before it can record an area."
            showMainWindow()
            return
        }
        var initial: AreaSelection?
        if sourceKind == .area, let displayID = selectedDisplayID {
            initial = AreaSelection(
                displayID: displayID,
                rect: CGRect(x: areaX, y: areaY, width: areaWidth, height: areaHeight))
        }
        areaPicker.present(intent: thenRecord ? .record : .useSelection, initial: initial) {
            [weak self] selection in
            guard let self else { return }
            if !self.isHarnessRun {
                HotkeyCenter.shared.intercept(.escape, nil)
                HotkeyCenter.shared.intercept(.returnKey, nil)
            }
            guard let selection else {
                if !thenRecord { self.showMainWindow() }
                return
            }
            self.apply(selection)
            if thenRecord {
                self.startCountdown()
            } else {
                self.showMainWindow()
            }
        }
        // The overlay covers every display, so capturing Esc/Return
        // system-wide while it is up takes nothing from anyone; it makes
        // both keys work even when the panels were refused key status.
        if areaPicker.isPresenting, !isHarnessRun {
            HotkeyCenter.shared.intercept(.escape) { [weak self] in self?.areaPicker.cancel() }
            HotkeyCenter.shared.intercept(.returnKey) { [weak self] in
                self?.areaPicker.commitCurrentSelection()
            }
        }
    }

    /// Adopt a picker result as the current source.
    func apply(_ selection: AreaSelection) {
        sourceKind = .area
        if displays.contains(where: { $0.displayID == selection.displayID }) {
            selectedDisplayID = selection.displayID
        }
        areaX = selection.rect.minX
        areaY = selection.rect.minY
        areaWidth = selection.rect.width
        areaHeight = selection.rect.height
        refreshSources()
        Task { await refreshSourcePreviewOnce() }
    }

    /// Menu bar "Record Window…": switch to window capture and bring the
    /// start screen forward on the window picker.
    func recordWindowFromMenuBar() {
        switch mode {
        case .countdown, .recording: return
        case .editor: closeEditor()
        case .start: break
        }
        sourceKind = .window
        refreshSources()
        showMainWindow()
    }

    func openProjectFromMenuBar(_ url: URL) {
        switch mode {
        case .countdown, .recording: return
        case .start, .editor: break
        }
        openProject(at: url)
        showMainWindow()
    }

    private(set) var hasInputMonitoring = EventTapSource.hasPermission()

    func refreshInputMonitoring() {
        hasInputMonitoring = EventTapSource.hasPermission()
    }

    /// Ask macOS for Input Monitoring. The request call is what REGISTERS
    /// this app in the System Settings list — without it the pane shows an
    /// empty list and users must add the app manually with "+". The system
    /// prompt appears at most once; if nothing changes, open the pane
    /// (where the app is now listed) with honest guidance.
    func requestInputMonitoring() {
        guard !EventTapSource.hasPermission() else {
            refreshInputMonitoring()
            return
        }
        _ = EventTapSource.requestPermission()
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            self.refreshInputMonitoring()
            if !self.hasInputMonitoring {
                self.openInputMonitoringSettings()
                self.statusMessage =
                    "macOS shows the Input Monitoring prompt only once — "
                    + "\(Branding.displayName) is now in the list; turn it on there."
            }
        }
    }

    func openInputMonitoringSettings() {
        if let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")
        {
            NSWorkspace.shared.open(url)
        }
    }

    /// Actively trigger the system Screen Recording consent dialog (a plain
    /// SCShareableContent failure does not always prompt), then re-check.
    func requestScreenRecording() {
        if !CGPreflightScreenCaptureAccess() {
            CGRequestScreenCaptureAccess()
            // macOS shows the system prompt at most ONCE per grant state;
            // every later call is a silent no-op (the button "does
            // nothing"). Give the prompt a moment — if nothing changed,
            // take the user to the actual switch instead.
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(2))
                if !CGPreflightScreenCaptureAccess() {
                    self.openScreenRecordingSettings()
                    self.statusMessage =
                        "macOS shows the permission prompt only once — turn on "
                        + "\(Branding.displayName) under Screen & System Audio "
                        + "Recording, then click Relaunch."
                }
                self.refreshDisplays()
            }
        }
        refreshDisplays()
    }

    /// Fix the stale-grant trap in one click: delete this app's Screen
    /// Recording row (removing the approval that points at an older build's
    /// signature), then ask macOS for a fresh prompt. The user approves it
    /// once; because the app is now signed with a stable identity, that
    /// approval survives every future rebuild.
    func repairScreenRecording() {
        guard let bundleID = Bundle.main.bundleIdentifier else {
            statusMessage = "Repair needs the bundled app (dist build), not swift run."
            return
        }
        let reset = Process()
        reset.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        reset.arguments = ["reset", "ScreenCapture", bundleID]
        do {
            try reset.run()
            reset.waitUntilExit()
        } catch {
            statusMessage = "Could not reset the old approval: \(error.localizedDescription)"
            return
        }
        CGRequestScreenCaptureAccess()
        screenPermission = .grantedAfterLaunch
        needsRelaunch = true
        statusMessage = "Approve the Screen Recording prompt (or flip the switch in System Settings), then hit Relaunch. This is the last time."
    }

    func openScreenRecordingSettings() {
        if let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
        {
            NSWorkspace.shared.open(url)
        }
    }

    /// Re-check permissions/displays whenever the user returns to the app
    /// (e.g. after toggling something in System Settings) so the UI updates
    /// without hunting for a refresh button.
    func startActivationRefresh() {
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.refreshDisplays()
                // Resume the live previews the resign handler paused.
                if case .start = self.mode {
                    self.startSourcePreviews()
                    if self.microphoneEnabled { self.micMonitor.start() }
                }
            }
        }
        // While the app is in the background its live previews are pure
        // waste (screenshot churn on WindowServer, an idle audio engine):
        // stop them and restart on activation.
        NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if case .start = self.mode {
                    self.stopSourcePreviews()
                    self.micMonitor.stop()
                }
            }
        }
    }

    func refreshDisplays() {
        refreshInputMonitoring()
        Task {
            let found = (try? await SCKCapture.availableDisplays()) ?? []
            self.displays = found
            if self.selectedDisplayID == nil {
                self.selectedDisplayID = found.first?.displayID
            }
            // Don't downgrade the explicit relaunch state on re-checks: a
            // just-granted permission still fails enumeration until relaunch.
            if !found.isEmpty {
                self.screenPermission = .granted
                self.needsRelaunch = false
                self.statusMessage = nil
            } else if self.screenPermission != .grantedAfterLaunch {
                self.screenPermission = ScreenPermissionState.diagnose(
                    preflightGranted: CGPreflightScreenCaptureAccess(),
                    displaysEnumerate: false)
            }
        }
    }

    func refreshSources() {
        Task {
            if sourceKind == .window {
                let found = (try? await SCKCapture.availableWindows()) ?? []
                self.windows = found
                if self.selectedWindowID == nil
                    || !found.contains(where: { $0.windowID == self.selectedWindowID })
                {
                    self.selectedWindowID = found.first?.windowID
                }
            }
            if sourceKind == .application {
                let found = (try? await SCKCapture.availableApps()) ?? []
                self.apps = found
                if self.selectedAppBundleID == nil
                    || !found.contains(where: { $0.bundleID == self.selectedAppBundleID })
                {
                    self.selectedAppBundleID = found.first?.bundleID
                }
                for app in self.apps where self.appIcons[app.bundleID] == nil {
                    if let url = NSWorkspace.shared.urlForApplication(
                        withBundleIdentifier: app.bundleID)
                    {
                        self.appIcons[app.bundleID] = NSWorkspace.shared.icon(forFile: url.path)
                    }
                }
            }
            self.fetchPickerThumbnails()
        }
    }

    /// Serial thumbnail sweep for the visual source cards; one in-flight
    /// sweep at a time, throttled — the cards are pickers, not live views,
    /// so refreshing them more than every 30 s is wasted WindowServer work.
    private var lastThumbnailSweep: Date = .distantPast
    private var lastThumbnailKind: CaptureSourceKind?

    private func fetchPickerThumbnails() {
        // Throttled per kind: switching to the Window tab must sweep
        // immediately even if displays were swept seconds ago.
        guard sourceKind != lastThumbnailKind
            || Date().timeIntervalSince(lastThumbnailSweep) > 30
        else { return }
        lastThumbnailSweep = Date()
        lastThumbnailKind = sourceKind
        thumbnailFetchTask?.cancel()
        let kind = sourceKind
        let displayList = displays
        let windowList = windows
        thumbnailFetchTask = Task { [weak self] in
            for display in displayList {
                if Task.isCancelled { return }
                if let image = try? await SCKCapture.previewImage(
                    kind: .display, displayID: display.displayID,
                    windowID: nil, appBundleID: nil, maxWidth: 360)
                {
                    self?.displayThumbnails[display.displayID] = image
                }
            }
            guard kind == .window else { return }
            for window in windowList.prefix(16) {
                if Task.isCancelled { return }
                if let image = try? await SCKCapture.previewImage(
                    kind: .window, displayID: window.displayID ?? 0,
                    windowID: window.windowID, appBundleID: nil, maxWidth: 320)
                {
                    self?.windowThumbnails[window.windowID] = image
                }
            }
        }
    }

    func refreshCameras() {
        let found = CameraCapture.availableCameras()
        self.cameras = found
        if selectedCameraID == nil || !found.contains(where: { $0.uniqueID == selectedCameraID }) {
            selectedCameraID = found.first?.uniqueID
        }
    }

    /// Center the area selection on the chosen display at a preset size.
    func centerArea(width: Double, height: Double) {
        guard let display = displays.first(where: { $0.displayID == selectedDisplayID }) else {
            return
        }
        let rect = SourceGeometry.centeredArea(
            width: width, height: height,
            displayWidthPoints: display.widthPoints,
            displayHeightPoints: display.heightPoints)
        areaX = rect.x
        areaY = rect.y
        areaWidth = rect.width
        areaHeight = rect.height
    }

    func setCameraEnabled(_ enabled: Bool) {
        cameraEnabled = enabled
        guard enabled else { return }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            refreshCameras()
        case .notDetermined:
            // @Sendable is load-bearing: the completion runs on an
            // arbitrary queue and must not inherit MainActor isolation
            // (the installTap crash mechanism, commit 71de209).
            AVCaptureDevice.requestAccess(for: .video) { @Sendable granted in
                Task { @MainActor [weak self] in
                    if granted { self?.refreshCameras() } else { self?.cameraEnabled = false }
                }
            }
        default:
            // "Denied" on a rebuilt app is usually our own stale TCC row,
            // not a real user decision: delete the row so macOS shows the
            // actual prompt, and only fall back to Settings if the user
            // denies that.
            pokeAVPermission(service: "Camera", mediaType: .video) { [weak self] granted in
                guard let self else { return }
                if granted {
                    self.statusMessage = nil
                    self.refreshCameras()
                } else {
                    self.cameraEnabled = false
                    self.statusMessage = "Camera stays off until it's allowed — the Camera privacy pane is open; flip the switch for \(Branding.displayName)."
                    if let url = URL(
                        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera")
                    {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
        }
    }

    /// Reset this app's TCC row for an AVFoundation service and re-request,
    /// so a stale "denied" becomes a real system prompt. The user still
    /// makes the actual grant decision.
    private func pokeAVPermission(
        service: String, mediaType: AVMediaType,
        completion: @escaping @MainActor (Bool) -> Void
    ) {
        if let bundleID = Bundle.main.bundleIdentifier {
            let reset = Process()
            reset.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
            reset.arguments = ["reset", service, bundleID]
            try? reset.run()
            reset.waitUntilExit()
        }
        AVCaptureDevice.requestAccess(for: mediaType) { @Sendable granted in
            Task { @MainActor in completion(granted) }
        }
    }

    // MARK: - Live source previews (start screen)

    /// Refresh loop for the "what will I record" thumbnail. Runs only while
    /// the start view is visible.
    private var previewRefreshObservers: [NSObjectProtocol] = []

    func startSourcePreviews() {
        stopSourcePreviews()
        // The preview is a framing aid, not a video feed. The old loop
        // asked WindowServer for a full-display screenshot every 2.5 s the
        // whole time the picker was open — each one forces a full-res
        // composite, which stuttered the ENTIRE system on loaded machines
        // (user-reported lag when previews refreshed continuously).
        // Refresh only when something actually changed: source selection
        // (the view's onChange handlers), the app coming to front, or our
        // window becoming key after the user rearranged their screen.
        Task { await refreshSourcePreviewOnce() }
        let center = NotificationCenter.default
        for name in [
            NSApplication.didBecomeActiveNotification,
            NSWindow.didBecomeKeyNotification,
        ] {
            previewRefreshObservers.append(
                center.addObserver(forName: name, object: nil, queue: .main) { _ in
                    Task { @MainActor [weak self] in
                        await self?.refreshSourcePreviewOnce()
                    }
                })
        }
        refreshCameraPreviewSession()
    }

    func stopSourcePreviews() {
        for observer in previewRefreshObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        previewRefreshObservers.removeAll()
        sourcePreviewTask?.cancel()
        sourcePreviewTask = nil
        thumbnailFetchTask?.cancel()
        thumbnailFetchTask = nil
        teardownCameraPreviewSession()
    }

    func refreshSourcePreviewOnce() async {
        guard let displayID = selectedDisplayID else { return }
        let image = try? await SCKCapture.previewImage(
            kind: sourceKind,
            displayID: displayID,
            windowID: selectedWindowID,
            appBundleID: selectedAppBundleID,
            maxWidth: 1280)
        if let image { self.sourcePreview = image }
    }

    /// Start-screen self-view: a lightweight preview-only session, torn
    /// down the moment the camera toggle goes off or the view goes away.
    func refreshCameraPreviewSession() {
        guard cameraEnabled,
            AVCaptureDevice.authorizationStatus(for: .video) == .authorized,
            let device = selectedCameraID.flatMap({ AVCaptureDevice(uniqueID: $0) })
                ?? AVCaptureDevice.default(for: .video)
        else {
            teardownCameraPreviewSession()
            return
        }
        teardownCameraPreviewSession()
        let session = AVCaptureSession()
        session.sessionPreset = .medium
        guard let input = try? AVCaptureDeviceInput(device: device),
            session.canAddInput(input)
        else { return }
        session.addInput(input)
        previewCameraSession = session
        // startRunning blocks; never on the main thread.
        DispatchQueue.global(qos: .userInitiated).async {
            session.startRunning()
        }
    }

    private func teardownCameraPreviewSession() {
        if let session = previewCameraSession {
            DispatchQueue.global(qos: .utility).async {
                session.stopRunning()
            }
        }
        previewCameraSession = nil
    }

    func refreshRecents() {
        let directory = recordingsDirectory
        Task {
            // Enumeration + manifest reads are file IO: off the main actor.
            let cards = await Task.detached(priority: .userInitiated) {
                let entries = (try? FileManager.default.contentsOfDirectory(
                    at: directory,
                    includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
                return entries
                    .filter { $0.pathExtension == AksSchema.packageExtension }
                    .compactMap { url -> ProjectCard? in
                        guard let info = ProjectQuickInfo.read(at: url) else {
                            return ProjectCard(
                                url: url,
                                modified: (try? url.resourceValues(
                                    forKeys: [.contentModificationDateKey]))?
                                    .contentModificationDate ?? .distantPast,
                                durationNs: nil, thumbnail: nil)
                        }
                        return ProjectCard(
                            url: url, modified: info.modified,
                            durationNs: info.durationNs, thumbnail: nil)
                    }
                    .sorted { $0.modified > $1.modified }
            }.value
            self.projectCards = cards
            self.recentProjects = cards.map(\.url)
            self.loadThumbnails()
        }
    }

    private var thumbnailTask: Task<Void, Never>?

    /// Serial thumbnail fill: cold-cache thumbnails decode real media, so
    /// one at a time keeps the disk and decoder calm; cached ones are a
    /// single PNG read each.
    private func loadThumbnails() {
        thumbnailTask?.cancel()
        let urls = projectCards.filter { $0.thumbnail == nil }.map(\.url)
        thumbnailTask = Task {
            for url in urls {
                if Task.isCancelled { return }
                let image = await ProjectThumbnailer.thumbnail(for: url)
                if let index = self.projectCards.firstIndex(where: { $0.url == url }) {
                    self.projectCards[index].thumbnail = image
                }
            }
        }
    }

    /// Exactly what the current selection will record — shown under the
    /// preview so a resolution drop is never a mystery (1× quality, area
    /// size, and window size all change it).
    var captureSummary: String {
        guard let display = displays.first(where: { $0.displayID == selectedDisplayID }) else {
            return ""
        }
        let scale = SourceGeometry.captureScale(
            nativeWidthPx: display.widthPx,
            widthPoints: display.widthPoints,
            native: captureQuality == .native)
        let resolved: SourceGeometry.Resolved
        switch sourceKind {
        case .display, .application:
            resolved = SourceGeometry.display(
                widthPoints: display.widthPoints,
                heightPoints: display.heightPoints, scale: scale)
        case .area:
            resolved = SourceGeometry.area(
                requested: AreaRect(x: areaX, y: areaY, width: areaWidth, height: areaHeight),
                displayWidthPoints: display.widthPoints,
                displayHeightPoints: display.heightPoints, scale: scale)
        case .window:
            guard let window = windows.first(where: { $0.windowID == selectedWindowID }) else {
                return ""
            }
            resolved = SourceGeometry.window(
                frame: window.frame,
                displayBounds: CGDisplayBounds(display.displayID), scale: scale)
        }
        let quality = captureQuality == .native ? "Retina" : "1×"
        return "Records \(resolved.widthPx)×\(resolved.heightPx) (\(quality)) @ \(Int(frameRate)) fps · HEVC"
    }

    var diskSummary: String {
        guard let display = displays.first(where: { $0.displayID == selectedDisplayID }) else {
            return ""
        }
        let pixels = captureQuality == .native
            ? Double(display.widthPx * display.heightPx)
            : Double(display.widthPoints * display.heightPoints)
        let videoBytesPerHour = pixels * frameRate * 0.1 / 8 * 3600
        let audioBytesPerHour = 48_000.0 * 4 * 3600
            * Double((microphoneEnabled ? 1 : 0) + (systemAudioEnabled ? 2 : 0))
        let gbPerHour = (videoBytesPerHour + audioBytesPerHour) / 1_073_741_824
        let free = (try? recordingsDirectory.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage ?? 0
        let freeGB = Double(free) / 1_073_741_824
        return String(
            format: "~%.1f GB/hour · %.0f GB free (≈ %.1f h headroom)",
            gbPerHour, freeGB, freeGB / max(gbPerHour, 0.001))
    }

    // MARK: - Recording flow

    private var countdownTask: Task<Void, Never>?

    /// Seconds of countdown for this launch: the user's setting, capped at
    /// one for harness runs so the panel never lingers on their screen.
    var effectiveCountdownSeconds: Int {
        isHarnessRun ? min(1, preferences.countdownSeconds) : preferences.countdownSeconds
    }

    /// Start recording with the current source/mic/camera settings — from
    /// the Record button, the menu bar, or the global hotkey. Works from
    /// the editor too (it closes first); ignored while a countdown or a
    /// recording is already running.
    func startCountdown() {
        switch mode {
        case .countdown, .recording: return
        case .editor: closeEditor()
        case .start: break
        }
        guard !displays.isEmpty else {
            statusMessage = "\(Branding.displayName) needs Screen Recording permission before it can record."
            showMainWindow()
            return
        }
        warnings = []
        let seconds = effectiveCountdownSeconds
        guard seconds > 0 else {
            mode = .countdown(0)
            countdownTask = Task { await self.beginRecording() }
            return
        }
        mode = .countdown(seconds)
        // The panel, not the main window, is the countdown the user sees:
        // it works when the window is hidden (hotkey / menu bar start) and
        // sits on the display about to be recorded.
        countdownPanel.show(
            remaining: seconds, onDisplayID: selectedDisplayID,
            onStartNow: { [weak self] in self?.skipCountdown() },
            onCancel: { [weak self] in self?.cancelCountdown() })
        // Esc must cancel even when another app is frontmost and the panel
        // was refused key status; released on every exit path below.
        if !isHarnessRun {
            HotkeyCenter.shared.intercept(.escape) { [weak self] in self?.cancelCountdown() }
        }
        countdownTask = Task {
            for remaining in stride(from: seconds, through: 1, by: -1) {
                if Task.isCancelled { return }
                mode = .countdown(remaining)
                countdownPanel.update(remaining: remaining)
                try? await Task.sleep(for: .seconds(1))
            }
            if Task.isCancelled { return }
            await self.beginRecording()
        }
    }

    /// Click / Return / the hotkey during the countdown: start now.
    func skipCountdown() {
        guard case .countdown = mode else { return }
        countdownTask?.cancel()
        dismissCountdownPanel()
        Task { await self.beginRecording() }
    }

    /// Esc during the countdown: never mind.
    func cancelCountdown() {
        guard case .countdown = mode else { return }
        countdownTask?.cancel()
        dismissCountdownPanel()
        mode = .start
    }

    private func dismissCountdownPanel() {
        countdownPanel.hide()
        if !isHarnessRun {
            HotkeyCenter.shared.intercept(.escape, nil)
        }
    }

    private func beginRecording() async {
        // Only the countdown path may start capture: ⌘O or any other mode
        // change during the countdown cancels the recording intent.
        guard case .countdown = mode else { return }
        // The countdown must be gone before the first frame is captured.
        dismissCountdownPanel()
        // The start-screen camera preview must release the device before
        // the recording session opens it.
        stopSourcePreviews()
        micMonitor.stop()
        guard let display = displays.first(where: { $0.displayID == selectedDisplayID }) else {
            statusMessage = "Select a display first."
            mode = .start
            showMainWindow()
            return
        }
        let stamp = RFC3339.now().replacingOccurrences(of: ":", with: "-").prefix(19)
        let projectURL = recordingsDirectory.appendingPathComponent("Recording \(stamp).aks")
        guard let configuration = makeConfiguration(display: display) else {
            mode = .start
            // The reason is in statusMessage; make sure it can be seen
            // even when the start came from the menu bar or a hotkey.
            showMainWindow()
            return
        }
        let coordinator = RecordingCoordinator(
            setup: .init(
                projectURL: projectURL,
                configuration: configuration,
                captureEvents: captureEvents,
                excludeOwnWindows: true),
            onWarning: { kind, message in
                Task { @MainActor [weak self] in
                    self?.warnings.append("[\(kind)] \(message)")
                }
            })
        do {
            try await coordinator.start()
            self.coordinator = coordinator
            self.recordingURL = projectURL
            self.recordingStartedAt = Date()
            self.isPaused = false
            self.pausedAt = nil
            self.totalPausedSeconds = 0
            self.activeCameraSession = (await coordinator.activeCamera())?.captureSession
            self.mode = .recording
            // Get out of the way: hide the app window entirely and control
            // the recording from the floating pill, the menu-bar item, or
            // the hotkeys. Floating the main window (the old behavior) kept
            // it above everything the user was trying to record.
            self.hideMainWindow()
            self.hudPanel.show(model: self, onDisplayID: display.displayID)
        } catch {
            // A permission granted while the app is running only takes
            // effect after relaunch; surface that instead of the raw error.
            let nsError = error as NSError
            if nsError.domain == "com.apple.ScreenCaptureKit.SCStreamErrorDomain",
                nsError.code == -3801
            {
                // Capture refused even though displays enumerated: either a
                // mid-session grant (needs relaunch) or a stale grant row.
                screenPermission = CGPreflightScreenCaptureAccess()
                    ? .grantedAfterLaunch : .denied
                statusMessage = screenPermission.guidance
                needsRelaunch = true
            } else {
                statusMessage = "Could not start recording: \(error.localizedDescription)"
            }
            // The failed attempt leaves an empty package behind; a project
            // that never started recording holds nothing recoverable.
            try? FileManager.default.removeItem(at: projectURL)
            refreshRecents()
            mode = .start
            showMainWindow()
        }
    }

    /// Resolve the selected source into a capture configuration: true pixel
    /// dimensions, the display's point→pixel scale, and the event offset
    /// that maps display-local cursor pixels into source pixels.
    private func makeConfiguration(display: SCKCapture.DisplayInfo) -> CaptureConfiguration? {
        let scale = SourceGeometry.captureScale(
            nativeWidthPx: display.widthPx,
            widthPoints: display.widthPoints,
            native: captureQuality == .native)

        let resolved: SourceGeometry.Resolved
        var windowID: UInt32?
        var appBundleID: String?
        switch sourceKind {
        case .display:
            resolved = SourceGeometry.display(
                widthPoints: display.widthPoints,
                heightPoints: display.heightPoints, scale: scale)
        case .area:
            resolved = SourceGeometry.area(
                requested: AreaRect(x: areaX, y: areaY, width: areaWidth, height: areaHeight),
                displayWidthPoints: display.widthPoints,
                displayHeightPoints: display.heightPoints, scale: scale)
        case .window:
            guard let window = windows.first(where: { $0.windowID == selectedWindowID }) else {
                statusMessage = "Pick a window first."
                return nil
            }
            windowID = window.windowID
            resolved = SourceGeometry.window(
                frame: window.frame,
                displayBounds: CGDisplayBounds(display.displayID), scale: scale)
        case .application:
            guard let bundleID = selectedAppBundleID else {
                statusMessage = "Pick an application first."
                return nil
            }
            appBundleID = bundleID
            resolved = SourceGeometry.application(
                widthPoints: display.widthPoints,
                heightPoints: display.heightPoints, scale: scale)
        }

        return CaptureConfiguration(
            widthPx: resolved.widthPx,
            heightPx: resolved.heightPx,
            nominalFrameRate: frameRate,
            videoCodec: .hevc,
            displayID: Int(display.displayID),
            sourceKind: sourceKind,
            windowID: windowID,
            appBundleID: appBundleID,
            areaRect: resolved.areaRect,
            displayScale: resolved.scale,
            eventOffsetXPx: resolved.eventOffsetXPx,
            eventOffsetYPx: resolved.eventOffsetYPx,
            microphoneEnabled: microphoneEnabled,
            systemAudioEnabled: systemAudioEnabled,
            cameraEnabled: cameraEnabled && selectedCameraID != nil,
            cameraDeviceID: selectedCameraID,
            captureKeystrokes: captureKeystrokes && captureEvents)
    }

    private var pauseInFlight = false

    func togglePause() {
        guard let coordinator, !pauseInFlight else { return }
        pauseInFlight = true
        defer {}
        Task {
            defer { self.pauseInFlight = false }
            do {
                if isPaused {
                    try await coordinator.resume()
                    if let pausedAt {
                        totalPausedSeconds += Date().timeIntervalSince(pausedAt)
                    }
                    pausedAt = nil
                    isPaused = false
                } else {
                    try await coordinator.pause()
                    pausedAt = Date()
                    isPaused = true
                }
            } catch {
                warnings.append("[pause] \(error)")
            }
        }
    }

    func stopRecording() {
        // Take ownership synchronously: the pill and the menu-bar item can
        // both fire, and the old guard passed twice because nil-ing
        // happened only after the long await.
        guard let coordinator = self.coordinator else { return }
        self.coordinator = nil
        isPaused = false
        Task {
            do {
                let summary = try await coordinator.stop()
                self.activeCameraSession = nil
                self.hudPanel.hide()
                self.showMainWindow()
                if !summary.validation.isHealthy {
                    self.warnings.append("Validation found problems — see aks validate.")
                }
                self.refreshRecents()
                if self.preferences.openEditorAfterRecording {
                    self.openProject(at: summary.projectURL)
                } else {
                    // Start screen; refreshRecents sorts newest first, so
                    // the recording just made leads the list.
                    self.mode = .start
                }
            } catch {
                self.activeCameraSession = nil
                self.hudPanel.hide()
                self.showMainWindow()
                self.statusMessage = "Stop failed: \(error)"
                self.mode = .start
            }
        }
    }

    /// Move a recording to the Trash (recoverable — never a hard delete).
    func trashProject(at url: URL) {
        do {
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
        } catch {
            statusMessage = "Could not move \(url.lastPathComponent) to Trash: \(error.localizedDescription)"
        }
        refreshRecents()
    }

    func revealProject(at url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    // MARK: - Editor flow

    func openProjectPanel() {
        switch mode {
        case .countdown, .recording: return
        case .start, .editor: break
        }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = recordingsDirectory
        panel.message = "Choose a .aks project"
        if panel.runModal() == .OK, let url = panel.url {
            openProject(at: url)
        }
    }

    func openProject(at url: URL) {
        if case .editor(let previous) = mode {
            previous.shutdown()
        }
        do {
            let player = try PreviewPlayer(projectURL: url)
            mode = .editor(player)
            statusMessage = nil
        } catch {
            statusMessage = "Could not open \(url.lastPathComponent): \(error)"
            mode = .start
        }
    }

    func closeEditor() {
        if case .editor(let player) = mode {
            player.shutdown()
        }
        refreshRecents()
        mode = .start
    }
}
