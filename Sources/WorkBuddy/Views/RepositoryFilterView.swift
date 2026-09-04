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

            VStack(alignment: .leading, spacing: 8) {
                TextField("Buscar repositorio…", text: $search)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Buscar repositorio")
                Text("Solo muestra un único repo. Mute oculta sus PRs y avisos. Se guarda automáticamente.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                if let solo = store.repositoryFilter.solo {
                    Text("Solo: \(solo) · Los muteos se conservan al salir de Solo.")
                        .font(.system(size: 10))
                        .foregroundStyle(Color.accentColor)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 12)
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
                    LazyVStack(spacing: 6) {
                        ForEach(repositories) { repository in
                            row(repository)
                        }
                    }
                    .padding(10)
                }
            }

            Divider()
            HStack {
                Text("\(repositories.count) de \(store.repositories.count) repositorios")
                Spacer()
                Text(store.repositoryFilter.isActive ? "Filtro activo" : "Todos visibles")
            }
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
    }

    private func row(_ repository: RepositoryFilter.Repository) -> some View {
        let solo = store.repositoryFilter.solo == repository.id
        let muted = store.repositoryFilter.muted.contains(repository.id)
        return HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(repository.id)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(2)
                    .help(repository.id)
                Text(repository.pullRequestCount == 0
                    ? "Sin resultados actuales · preferencia guardada"
                    : "\(repository.pullRequestCount) PRs" + (store.repositoryFilter.includes(repository.id) ? "" : " · ocultos"))
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            filterButton("Solo", active: solo, tint: .orange,
                         help: solo ? "Dejar de ver solo este" : "Ver solo este") {
                store.toggleRepositorySolo(repository.id)
            }
            .accessibilityLabel("Ver solo \(repository.id)")
            filterButton("Mute", active: muted && !solo, tint: .red,
                         help: solo || !muted ? "Mutear repositorio" : "Dejar de mutear") {
                store.toggleRepositoryMute(repository.id)
            }
            .accessibilityLabel("Mutear \(repository.id)")
        }
        .padding(10)
        .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
    }

    private func filterButton(
        _ title: String, active: Bool, tint: Color, help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(active ? tint : Color.secondary)
                .frame(width: 42, height: 28)
                .background(active ? tint.opacity(0.16) : Color.secondary.opacity(0.08),
                            in: RoundedRectangle(cornerRadius: 6))
                .overlay {
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(active ? tint.opacity(0.5) : Color.clear, lineWidth: 1)
                }
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityValue(active ? "Activado" : "Desactivado")
    }
}
