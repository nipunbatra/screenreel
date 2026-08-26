import AppKit
import SwiftUI

@main
struct AksApplication: App {
    @State private var model = AppModel()

    init() {
        // Running as a bare SwiftPM executable (swift run AksApp): become a
        // regular, activatable app with a Dock icon and key windows.
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate()
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
        WindowGroup(Branding.displayName) {
            ContentView()
                .environment(model)
                .preferredColorScheme(.dark)
                // Every label in the app is copyable — error messages
                // especially, so they can be pasted into a bug report.
                .textSelection(.enabled)
                .frame(minWidth: 960, minHeight: 600)
                .onAppear {
                    // Bare-executable launches start inactive; front the app
                    // once the first window exists.
                    NSApplication.shared.activate()
                    model.startAutopilotIfRequested()
                }
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open Project…") {
                    model.openProjectPanel()
                }
                .keyboardShortcut("o")
            }
        }

        // Menu-bar recording control: stop or pause from any app without
        // hunting for the HUD window.
        MenuBarExtra(isInserted: .constant(model.isRecordingMode)) {
            Text(model.isPaused ? "Paused · \(model.elapsedText)" : "Recording · \(model.elapsedText)")
            Button(model.isPaused ? "Resume" : "Pause") {
                model.togglePause()
            }
            Button("Stop Recording") {
                model.stopRecording()
                NSApplication.shared.activate()
            }
            .keyboardShortcut(".", modifiers: [.command, .shift])
        } label: {
            Image(systemName: model.isPaused ? "pause.circle.fill" : "record.circle.fill")
        }
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

    var body: some View {
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
}
