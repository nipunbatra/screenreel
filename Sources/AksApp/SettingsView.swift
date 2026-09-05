import AppSupport
import SwiftUI

/// The Settings window (⌘,): menu bar, shortcuts, countdown, recordings
/// folder, and what happens when a recording stops. Every control writes
/// through `AppModel.updatePreferences`, which persists and re-registers
/// hotkeys in one place.
struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            Section("General") {
                Toggle("Show in menu bar", isOn: binding(\.showInMenuBar))
                Picker("Countdown", selection: binding(\.countdownSeconds)) {
                    Text("Off").tag(0)
                    Text("3 seconds").tag(3)
                    Text("5 seconds").tag(5)
                }
                Toggle("Open the editor when a recording stops",
                    isOn: binding(\.openEditorAfterRecording))
                Text("When off, stopping lands on the start screen with the new recording listed first.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Shortcuts") {
                ForEach(HotkeyAction.allCases) { action in
                    Picker(action.title, selection: Binding(
                        get: { model.preferences.hotkey(for: action) },
                        set: { model.setHotkey($0, for: action) }))
                    {
                        ForEach(HotkeyPreset.allCases) { preset in
                            Text(preset.label).tag(preset)
                        }
                    }
                }
                let failures = model.hotkeyFailures
                if failures.isEmpty {
                    Text("Shortcuts work while any app is in front and need no extra permission. A chord can drive only one action.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(HotkeyAction.allCases.filter { failures[$0] != nil }) { action in
                        Label(
                            "\(model.preferences.hotkey(for: action).label) could not be registered for “\(action.title)” — another app may hold it. Pick a different preset.",
                            systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                    }
                }
            }

            Section("Recordings") {
                LabeledContent("Folder") {
                    HStack(spacing: 8) {
                        Text(model.recordingsDirectoryDisplayPath)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                        Button("Change…") {
                            model.chooseRecordingsFolder()
                        }
                        if model.preferences.recordingsFolderPath != nil {
                            Button("Use Default") {
                                model.resetRecordingsFolder()
                            }
                        }
                    }
                }
                Text("New recordings are saved here as recoverable .aks packages. If the folder disappears, \(Branding.displayName) falls back to ~/Movies/Aks.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 500)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func binding<T>(_ keyPath: WritableKeyPath<Preferences, T>) -> Binding<T> {
        Binding(
            get: { model.preferences[keyPath: keyPath] },
            set: { value in model.updatePreferences { $0[keyPath: keyPath] = value } })
    }
}
