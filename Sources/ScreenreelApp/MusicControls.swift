import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct MusicControls: View {
    @Bindable var player: PreviewPlayer

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider()
            Text("Background music").font(.callout.weight(.medium))
            if let music = player.edits.music {
                Label(music.name, systemImage: "music.note")
                    .font(.caption).lineLimit(1).help(music.name)
                HStack {
                    Text("Volume").font(.caption)
                    Slider(value: Binding(
                        get: { Double(player.edits.music?.gain ?? 0) },
                        set: { value in player.updateEdits(kind: "music-volume") { $0.music?.volume = value } }), in: 0...1)
                        .accessibilityLabel("Music volume")
                    Text("\(Int(music.gain * 100))%")
                        .font(.caption.monospacedDigit()).frame(width: 36, alignment: .trailing)
                }
                Toggle("Loop to fill the video", isOn: Binding(
                    get: { player.edits.music?.loops ?? true },
                    set: { value in player.updateEdits(kind: "music-loop") { $0.music?.loops = value } }))
                    .font(.caption)
                HStack {
                    Button("Replace…", action: chooseMusic)
                    Button("Remove") { player.updateEdits(kind: "music-remove") { $0.music = nil } }
                }.disabled(player.isImportingMusic)
            } else {
                Button(action: chooseMusic) { Label("Add Music…", systemImage: "music.note.list") }
                    .disabled(player.isImportingMusic)
            }
            if player.isImportingMusic {
                HStack { ProgressView().controlSize(.small); Button("Cancel", action: player.cancelMusicImport) }
            }
            if let status = player.musicStatus {
                Text(status).font(.caption).foregroundStyle(.secondary)
            }
            Text("MP3, M4A, WAV or AIFF. Plays in preview and styled exports. The original is kept in your project.")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func chooseMusic() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Choose a music file to copy into this project."
        panel.begin { response in
            if response == .OK, let url = panel.url { player.importMusic(from: url) }
        }
    }
}
