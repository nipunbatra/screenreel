import Captions
import SwiftUI

/// Editable transcript: every cue is a text field; clicking a timestamp
/// seeks the preview there. Edits persist to the project and flow into
/// the next SRT/VTT export.
struct TranscriptView: View {
    @Bindable var player: PreviewPlayer
    @Binding var isPresented: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Transcript")
                    .font(.title3.bold())
                Text("\(player.captions.count) cues")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Done") { isPresented = false }
                    .keyboardShortcut(.escape, modifiers: [])
            }
            .padding(14)
            Divider().overlay(.white.opacity(0.08))
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(player.captions) { cue in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Button {
                                player.seekToCue(cue)
                            } label: {
                                Text(CaptionWriter.timestamp(cue.startNs, format: .vtt))
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .help("Jump here")
                            TextField(
                                "",
                                text: Binding(
                                    get: { cue.text },
                                    set: { player.setCaptionText($0, cueID: cue.id) }),
                                axis: .vertical)
                                .textFieldStyle(.plain)
                                .font(.callout)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 3)
                    }
                }
                .padding(.vertical, 10)
            }
        }
        .frame(width: 520, height: 480)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
    }
}
