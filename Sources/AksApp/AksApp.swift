import AppKit
import SwiftUI

@main
struct AksApplication: App {
    @State private var model = AppModel()

    init() {
        // Opt out of persistent UI state before AppKit reads it. A signed
        // build restores window state at launch; the state file is per
        // bundle id and shared by every build, and after a session that
        // ended with the main window hidden (it is ordered out while
        // recording), a killed process, or a build whose main scene had a
        // different identity, macOS restores ZERO windows and SwiftUI never
        // presents one — not even with defaultLaunchBehavior(.presented) —
        // so the app "launches" as a bare Dock icon. Unsigned dev builds
        // skipped restoration, which hid this. Equivalent to launching with
        // -ApplePersistenceIgnoreState YES; the app has one fixed-layout
        // window, so losing frame restoration costs nothing.
        UserDefaults.standard.register(defaults: ["ApplePersistenceIgnoreState": true])
        // Running as a bare SwiftPM executable (swift run AksApp): become a
        // regular, activatable app with a Dock icon and key windows.
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate()
        UpdateChecker.shared.scheduleAutomaticCheck()  // at most once per 24 h; see UpdateCheck.swift
        if let debugPath = ProcessInfo.processInfo.environment["AKS_DEBUG_WINDOWS_FILE"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                let windows = NSApplication.shared.windows.map {
                    "\($0.title) visible=\($0.isVisible) frame=\($0.frame)"
                }
                try? "AKS_DEBUG windows: \(windows)\n"
                    .write(toFile: debugPath, atomically: true, encoding: .utf8)
            }
        }
    }

    var body: some Scene {
        // A single document window (not a WindowGroup): the menu bar and
        // hotkeys reopen it by id after the user closes it, and there is
        // never a second copy of the start screen.
        Window(Branding.displayName, id: "main") {
            ContentView()
                .environment(model)
                .preferredColorScheme(.dark)
                // Every label in the app is copyable — error messages
                // especially, so they can be pasted into a bug report.
                .textSelection(.enabled)
                .frame(minWidth: 960, minHeight: 600)
        }
        // Present at launch, centered (saved state is ignored — see init).
        .defaultLaunchBehavior(.presented)
        .restorationBehavior(.disabled)
        .defaultPosition(.center)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open Project…") {
                    model.openProjectPanel()
                }
                .keyboardShortcut("o")
            }
            CommandGroup(after: .appInfo) {
                DistributionCommands()  // Enter License…, Check for Updates…
            }
        }

        // ⌘, — menu bar, global shortcuts, countdown, recordings folder.
        Settings {
            SettingsView()
                .environment(model)
                .preferredColorScheme(.dark)
        }

        // The menu-bar status item is AppKit (MenuBarController), owned by
        // the model: it exists whenever "Show in menu bar" is on, and
        // always while recording.
    }
}

extension AppModel {
    var isRecordingMode: Bool {
        if case .recording = mode { return true }
        return false
    }
}

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Group {
            switch model.mode {
            case .start:
                StartView()
            case .countdown(let remaining):
                CountdownView(remaining: remaining)
            case .recording:
                RecordingHUDView()
            case .editor(let player):
                EditorView(player: player)
            }
        }
        .onAppear {
            // Bare-executable launches start inactive; front the app once
            // the first window exists.
            NSApplication.shared.activate()
            // Hand the model a way to reopen this window and Settings from
            // the menu bar / hotkeys (SwiftUI only exposes these to views).
            model.openMainWindowAction = { openWindow(id: "main") }
            model.openSettingsAction = { openSettings() }
            model.installMenuBarAndHotkeys()
            model.startAutopilotIfRequested()
            model.startUXSelfTestIfRequested()
        }
    }
}
