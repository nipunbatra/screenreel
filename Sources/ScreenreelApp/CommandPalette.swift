import SwiftUI

/// ⌘K command palette for the editor: type-to-filter every editor action,
/// Enter runs the top hit. Keyboard-first cutting for 90-minute lectures.
struct PaletteCommand: Identifiable {
    let id = UUID()
    let title: String
    let icon: String
    let hint: String?
    let action: @MainActor () -> Void

    /// Case-insensitive subsequence match ("dds" hits "Detect dead stretches").
    func matches(_ query: String) -> Bool {
        guard !query.isEmpty else { return true }
        var remainder = Substring(title.lowercased())
        for character in query.lowercased() {
            guard let index = remainder.firstIndex(of: character) else { return false }
            remainder = remainder[remainder.index(after: index)...]
        }
        return true
    }
}

struct CommandPaletteView: View {
    let commands: [PaletteCommand]
    @Binding var isPresented: Bool
    @State private var query = ""
    @State private var selection = 0
    @FocusState private var fieldFocused: Bool

    private var filtered: [PaletteCommand] {
        commands.filter { $0.matches(query) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "command")
                    .foregroundStyle(.secondary)
                TextField("Type a command…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($fieldFocused)
                    .onSubmit { runSelected() }
            }
            .padding(14)
            Divider().overlay(.white.opacity(0.08))
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(Array(filtered.enumerated()), id: \.element.id) { index, command in
                            HStack(spacing: 10) {
                                Image(systemName: command.icon)
                                    .frame(width: 18)
                                    .foregroundStyle(index == selection ? .primary : .secondary)
                                Text(command.title)
                                Spacer()
                                if let hint = command.hint {
                                    Text(hint)
                                        .font(.caption.monospaced())
                                        .foregroundStyle(.tertiary)
                                }
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(
                                index == selection ? Color.accentColor.opacity(0.25) : .clear,
                                in: RoundedRectangle(cornerRadius: 7))
                            .contentShape(Rectangle())
                            .onTapGesture {
                                selection = index
                                runSelected()
                            }
                            .id(index)
                        }
                    }
                    .padding(8)
                }
                .frame(maxHeight: 320)
                .onChange(of: selection) { _, new in
                    proxy.scrollTo(new)
                }
            }
        }
        .frame(width: 460)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(.white.opacity(0.12)))
        .onAppear {
            query = ""
            selection = 0
            fieldFocused = true
        }
        .onChange(of: query) { selection = 0 }
        .onKeyPress(.downArrow) {
            selection = min(selection + 1, max(0, filtered.count - 1))
            return .handled
        }
        .onKeyPress(.upArrow) {
            selection = max(0, selection - 1)
            return .handled
        }
        .onKeyPress(.escape) {
            isPresented = false
            return .handled
        }
    }

    private func runSelected() {
        guard filtered.indices.contains(selection) else { return }
        let command = filtered[selection]
        isPresented = false
        command.action()
    }
}
