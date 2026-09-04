import SwiftUI

/// Ocupa todo el panel para que la lista siga siendo cómoda con muchos repos.
struct RepositoryFilterView: View {
    let store: ReviewQueueStore
    let close: () -> Void

    @State private var search = ""

    private var repositories: [RepositoryFilter.Repository] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return store.repositories.filter { query.isEmpty || $0.id.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button(action: close) {
                    Label("Volver", systemImage: "chevron.left")
                }
                .buttonStyle(.borderless)
                Spacer()
                Text("Repositorios").font(.system(size: 13, weight: .semibold))
                Spacer()
                Button("Ver todos") { store.clearRepositoryFilter() }
                    .buttonStyle(.borderless)
                    .disabled(!store.repositoryFilter.isActive)
            }
            .padding(14)

            TextField("Buscar repositorio…", text: $search)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Buscar repositorio")
                .padding(.horizontal, 14)
                .padding(.bottom, 10)
            Divider()

            if repositories.isEmpty {
                ContentUnavailableView {
                    Label("Sin repositorios", systemImage: "folder")
                } description: {
                    Text(search.isEmpty
                        ? "Los repositorios aparecerán al cargar los resultados de GitHub."
                        : "No hay repositorios que coincidan con la búsqueda.")
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
    }

    private func row(_ repository: RepositoryFilter.Repository) -> some View {
        let favorite = store.repositoryFilter.favorites.contains(repository.id)
        let solo = store.repositoryFilter.solo.contains(repository.id)
        let muted = store.repositoryFilter.muted.contains(repository.id)
        return HStack(spacing: 6) {
            filterButton(favorite ? "star.fill" : "star", active: favorite, tint: .yellow,
                         help: favorite ? "Quitar de favoritos" : "Marcar como favorito") {
                store.toggleRepositoryFavorite(repository.id)
            }
            .accessibilityLabel("Favorito: \(repository.id)")

            Text(repository.id)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)
                .help(repository.id)
                .frame(maxWidth: .infinity, alignment: .leading)

            filterButton(solo ? "eye.fill" : "eye", active: solo, tint: .orange,
                         help: solo ? "Quitar de la selección" : "Ver solo los repositorios seleccionados") {
                store.toggleRepositorySolo(repository.id)
            }
            .accessibilityLabel("Seleccionar \(repository.id)")
            filterButton(muted ? "speaker.slash.fill" : "speaker.slash", active: muted, tint: .red,
                         help: muted ? "Dejar de mutear" : "Mutear repositorio") {
                store.toggleRepositoryMute(repository.id)
            }
            .accessibilityLabel("Mutear \(repository.id)")
        }
        .frame(height: 30)
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
        .accessibilityValue(active ? "Activado" : "Desactivado")
    }
}
