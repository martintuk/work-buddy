import AppKit
import SwiftUI

struct ItemNoteButton: View {
    let itemID: LocalNoteID
    var isRowHovering = false
    var store: LocalNoteStore = .shared

    @AppStorage("appearance.language") private var language = "es"
    @State private var isPresented = false
    @State private var isHovering = false

    private var hasNote: Bool { !store.text(for: itemID).isEmpty }
    private var label: String {
        if language == "en" {
            return hasNote ? "Edit local note" : "Add local note"
        }
        return hasNote ? "Editar nota local" : "Agregar nota local"
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
                label: label,
                placeholder: language == "en" ? "Write a note…" : "Escribí una nota…"
            )
        }
    }
}

private struct LocalNoteEditor: View {
    @Binding var text: String
    let label: String
    let placeholder: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NoteTextView(text: $text, label: label, onDismiss: { dismiss() })
            .overlay(alignment: .topLeading) {
                if text.isEmpty {
                    Text(placeholder)
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .frame(width: 260, height: 130)
            .padding(8)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color.accentColor.opacity(0.5), lineWidth: 1)
            }
            .padding(8)
    }
}

private struct NoteTextView: NSViewControllerRepresentable {
    @Binding var text: String
    let label: String
    let onDismiss: () -> Void

    func makeNSViewController(context: Context) -> EditorController {
        let controller = EditorController()
        controller.loadViewIfNeeded()
        return controller
    }

    func updateNSViewController(_ controller: EditorController, context: Context) {
        controller.onChange = { text = $0 }
        controller.onDismiss = onDismiss
        controller.textView.setAccessibilityLabel(label)
        // Avoid resetting the selection or an in-progress input-method composition.
        if controller.textView.string != text {
            controller.textView.string = text
        }
    }

    final class EditorController: NSViewController, NSTextViewDelegate {
        let textView = NSTextView()
        var onChange: (String) -> Void = { _ in }
        var onDismiss: () -> Void = {}

        override func loadView() {
            let scrollView = NSScrollView()
            scrollView.drawsBackground = false
            scrollView.hasVerticalScroller = true
            scrollView.autohidesScrollers = true
            textView.isRichText = false
            textView.isAutomaticQuoteSubstitutionEnabled = false
            textView.isAutomaticDashSubstitutionEnabled = false
            textView.allowsUndo = true
            textView.font = .systemFont(ofSize: 12)
            textView.textColor = .textColor
            textView.insertionPointColor = .controlAccentColor
            textView.drawsBackground = false
            textView.textContainerInset = .zero
            textView.textContainer?.lineFragmentPadding = 0
            textView.isVerticallyResizable = true
            textView.autoresizingMask = [.width]
            textView.textContainer?.widthTracksTextView = true
            textView.delegate = self
            scrollView.documentView = textView
            view = scrollView
        }

        override func viewDidAppear() {
            super.viewDidAppear()
            // SwiftUI's onAppear can precede the popover window becoming ready.
            // Focus the actual editor only once AppKit has presented its window.
            guard let window = view.window else { return }
            NSApp.activate(ignoringOtherApps: true)
            window.makeKey()
            window.makeFirstResponder(textView)
            textView.setSelectedRange(NSRange(location: textView.string.utf16.count, length: 0))
            textView.scrollRangeToVisible(textView.selectedRange())
        }

        func textDidChange(_ notification: Notification) {
            onChange(textView.string)
        }

        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            guard commandSelector == #selector(NSResponder.cancelOperation(_:)) else { return false }
            onDismiss()
            return true
        }
    }
}
