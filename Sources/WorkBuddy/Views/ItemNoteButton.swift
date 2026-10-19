import SwiftUI

struct ItemNoteButton: View {
    let itemID: LocalNoteID
    var isRowHovering = false
    var store: LocalNoteStore = .shared

    @State private var isPresented = false
    @State private var isHovering = false

    private var hasNote: Bool { !store.text(for: itemID).isEmpty }
    private var label: String {
        hasNote ? "Edit local note" : "Add local note"
    }

    var body: some View {
        Button { isPresented.toggle() } label: {
            Image(systemName: hasNote ? "note.text" : "square.and.pencil")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(hasNote || isPresented ? Color.accentColor : Color.primary)
                .frame(width: 18, height: 18)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .opacity(hasNote || isPresented || isHovering || isRowHovering ? 1 : 0.3)
        .help(label)
        .accessibilityLabel(label)
        .onHover { isHovering = $0 }
        .popover(isPresented: $isPresented, attachmentAnchor: .rect(.bounds), arrowEdge: .trailing) {
            LocalNoteEditor(
                text: Binding(
                    get: { store.text(for: itemID) },
                    set: { store.setText($0, for: itemID) }
                ),
                label: label
            )
        }
    }
}

private struct LocalNoteEditor: View {
    @Binding var text: String
    let label: String
    @FocusState private var isFocused: Bool
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        TextEditor(text: $text)
            .font(.system(size: 12))
            .scrollContentBackground(.hidden)
            .focused($isFocused)
            .accessibilityLabel(label)
            .frame(width: 260, height: 130)
            .padding(10)
            .onAppear { isFocused = true }
            .onExitCommand { dismiss() }
    }
}
