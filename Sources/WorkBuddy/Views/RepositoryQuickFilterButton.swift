import SwiftUI

/// Access the panel's filters, anchored to a PR's repository name.
struct RepositoryQuickFilterButton: View {
    let repository: String
    let store: ReviewQueueStore

    @State private var isPresented = false
    @State private var isHovering = false

    private var repositoryID: String { repository.lowercased() }
    private var isSolo: Bool { store.repositoryFilter.solo.contains(repositoryID) }
    private var isMuted: Bool { store.repositoryFilter.muted.contains(repositoryID) }

    var body: some View {
        Button { isPresented = true } label: {
            Text(repository.split(separator: "/").last.map(String.init) ?? repository)
                .foregroundStyle(isHovering || isPresented ? Color.accentColor : Color.secondary)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help("\(repository) · \(L10n.text(.repositoriesFilterHelp))")
        .accessibilityLabel("\(L10n.text(.repositoriesFilterHelp)): \(repository)")
        .onHover { isHovering = $0 }
        .popover(isPresented: $isPresented, attachmentAnchor: .rect(.bounds), arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 4) {
                Text(repository)
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(repository)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                Divider()
                action(
                    title: L10n.text(isSolo ? .repositoriesDeselect : .repositoriesSolo),
                    symbol: isSolo ? "eye.fill" : "eye", active: isSolo, tint: .orange
                ) {
                    store.toggleRepositorySolo(repository)
                }
                action(
                    title: L10n.text(isMuted ? .repositoriesUnmute : .repositoriesMute),
                    symbol: isMuted ? "speaker.slash.fill" : "speaker.slash", active: isMuted, tint: .red
                ) {
                    store.toggleRepositoryMute(repository)
                }
            }
            .padding(8)
            .frame(width: 270)
            .onExitCommand { isPresented = false }
        }
    }

    private func action(
        title: String, symbol: String, active: Bool, tint: Color,
        perform: @escaping () -> Void
    ) -> some View {
        Button {
            // Close before filtering: muting can remove the row anchoring the popover.
            isPresented = false
            perform()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .foregroundStyle(active ? tint : .secondary)
                    .frame(width: 16)
                Text(title)
                Spacer(minLength: 0)
                if active {
                    Image(systemName: "checkmark")
                        .foregroundStyle(tint)
                }
            }
            .font(.system(size: 11))
            .padding(.horizontal, 8)
            .frame(height: 28)
            .contentShape(.rect)
        }
        .buttonStyle(RepositoryActionButtonStyle())
        .help(title)
        .accessibilityValue(L10n.text(active ? .commonEnabled : .commonDisabled))
    }
}

private struct RepositoryActionButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Content(configuration: configuration)
    }

    private struct Content: View {
        let configuration: ButtonStyle.Configuration
        @State private var isHovering = false

        var body: some View {
            configuration.label
                .foregroundStyle(.primary)
                .background(
                    Color.primary.opacity(configuration.isPressed ? 0.14 : isHovering ? 0.08 : 0),
                    in: RoundedRectangle(cornerRadius: 6)
                )
                .onHover { isHovering = $0 }
                .animation(.easeOut(duration: 0.12), value: isHovering)
                .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
        }
    }
}
