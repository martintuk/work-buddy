import SwiftUI

/// The editor can only be selected in Settings.
struct EditorPicker: View {
    let store: EditorStore
    @State private var error: String?

    var body: some View {
        Menu {
            ForEach(store.choices) { editor in
                Button {
                    store.select(editor)
                } label: {
                    if editor.url == store.selectedURL {
                        Label(editor.name, systemImage: "checkmark")
                    } else {
                        Text(editor.name)
                    }
                }
                .help(editor.url.path)
            }
            if !store.choices.isEmpty { Divider() }
            Button(L10n.text(.editorOther)) {
                do {
                    try store.chooseOther()
                } catch {
                    self.error = error.localizedDescription
                }
            }
        } label: {
            Text(store.selectedName ?? L10n.text(.editorChoose))
                .lineLimit(1)
        }
        .fixedSize()
        .accessibilityLabel(L10n.text(.settingsEditor))
        .help(store.selectedURL?.path ?? L10n.text(.editorChoose))
        .task { await store.refresh() }
        .alert(L10n.text(.settingsEditor), isPresented: Binding(
            get: { error != nil }, set: { if !$0 { error = nil } }
        )) {
            Button(L10n.text(.commonBack), role: .cancel) { error = nil }
        } message: {
            Text(error ?? "")
        }
    }
}
