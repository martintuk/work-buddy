import AppKit
import SwiftUI

/// Ocupa todo el panel para que la lista siga siendo cómoda con muchos repos.
struct RepositoryFilterView: View {
    let store: ReviewQueueStore
    var parentWindow: () -> NSWindow? = { nil }
    let close: () -> Void

    @State private var search = ""
    @State private var showingFolderError = false

    private var repositories: [RepositoryFilter.Repository] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return store.repositories.filter { query.isEmpty || $0.id.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button(action: close) {
                    Label(L10n.text(.commonBack), systemImage: "chevron.left")
                }
                .buttonStyle(.borderless)
                Spacer()
            }
            .overlay {
                Text(L10n.text(.repositoriesTitle)).font(.system(size: 13, weight: .semibold))
            }
            .padding(14)

            HStack(spacing: 8) {
                TextField(L10n.text(.repositoriesSearchPlaceholder), text: $search)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel(L10n.text(.repositoriesSearch))
                Button(L10n.text(.commonClear)) { store.clearRepositoryFilter() }
                    .buttonStyle(.borderless)
                    .disabled(!store.repositoryFilter.isActive)
                    .fixedSize()
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 10)
            Divider()

            if repositories.isEmpty {
                ContentUnavailableView {
                    Label(L10n.text(.repositoriesEmpty), systemImage: "folder")
                } description: {
                    Text(search.isEmpty
                        ? L10n.text(.repositoriesNotLoaded)
                        : L10n.text(.repositoriesNoMatches))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(repositories) { repository in
                            row(repository)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                }
                .scrollIndicators(.hidden)
            }
        }
        .alert(L10n.text(.repositoriesInvalidFolder), isPresented: $showingFolderError) {
            Button(L10n.text(.commonBack), role: .cancel) {}
        }
    }

    private func chooseFolder(for repository: String) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.title = L10n.text(.repositoriesAssociateFolder, repository)
        panel.prompt = L10n.text(.repositoriesChooseFolder)
        panel.directoryURL = store.localRepositories.folder(for: repository)
        NSApp.activate(ignoringOtherApps: true)
        let completion: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let folder = panel.url else { return }
            do {
                try store.localRepositories.associate(folder, with: repository)
            } catch {
                showingFolderError = true
            }
        }
        if let window = parentWindow() {
            // Una sheet queda ligada al popover y AppKit la mantiene por delante.
            panel.beginSheetModal(for: window, completionHandler: completion)
        } else {
            completion(panel.runModal())
        }
    }

    private func row(_ repository: RepositoryFilter.Repository) -> some View {
        let favorite = store.repositoryFilter.favorites.contains(repository.id)
        let solo = store.repositoryFilter.solo.contains(repository.id)
        let muted = store.repositoryFilter.muted.contains(repository.id)
        return HStack(spacing: 6) {
            filterButton(favorite ? "star.fill" : "star", active: favorite, tint: .yellow,
                         help: favorite ? L10n.text(.repositoriesUnfavorite) : L10n.text(.repositoriesFavorite)) {
                store.toggleRepositoryFavorite(repository.id)
            }
            .accessibilityLabel(L10n.text(.repositoriesFavoriteAccessibility, repository.id))

            Text(repository.id)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)
                .help(repository.id)
                .frame(maxWidth: .infinity, alignment: .leading)

            folderButton(for: repository.id)

            filterButton(solo ? "eye.fill" : "eye", active: solo, tint: .orange,
                         help: solo ? L10n.text(.repositoriesDeselect) : L10n.text(.repositoriesSolo)) {
                store.toggleRepositorySolo(repository.id)
            }
            .accessibilityLabel(L10n.text(.repositoriesSelectAccessibility, repository.id))
            filterButton(muted ? "speaker.slash.fill" : "speaker.slash", active: muted, tint: .red,
                         help: muted ? L10n.text(.repositoriesUnmute) : L10n.text(.repositoriesMute)) {
                store.toggleRepositoryMute(repository.id)
            }
            .accessibilityLabel(L10n.text(.repositoriesMuteAccessibility, repository.id))
        }
        .frame(height: 30)
    }

    private func folderButton(for repository: String) -> some View {
        let folder = store.localRepositories.folder(for: repository)
        return Button { chooseFolder(for: repository) } label: {
            Image(systemName: folder == nil ? "folder.badge.plus" : "folder.fill")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(folder == nil ? Color.secondary : Color.accentColor)
                .frame(width: 26, height: 26)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help(folder?.path ?? L10n.text(.repositoriesAssociateFolder, repository))
        .accessibilityLabel(L10n.text(.repositoriesAssociateFolder, repository))
        .accessibilityValue(folder?.path ?? L10n.text(.repositoriesNoFolder))
        .contextMenu {
            Button(L10n.text(.repositoriesChooseFolder)) { chooseFolder(for: repository) }
            if folder != nil {
                Button(L10n.text(.repositoriesRemoveFolder)) {
                    store.localRepositories.removeFolder(for: repository)
                }
            }
        }
    }

    private func filterButton(
        _ symbol: String, active: Bool, tint: Color, help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(active ? tint : Color.secondary)
                .frame(width: 26, height: 26, alignment: .trailing)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityValue(active ? L10n.text(.commonEnabled) : L10n.text(.commonDisabled))
    }
}
