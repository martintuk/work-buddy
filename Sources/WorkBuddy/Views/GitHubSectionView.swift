import SwiftUI

/// Cola de PRs de la sección GitHub.
struct GitHubSectionView: View {
    let store: ReviewQueueStore

    @State private var expanded: Set<CollapsibleSection> = []
    @State private var pendingMerge: PendingMerge?

    /// Merge esperando confirmación.
    struct PendingMerge: Identifiable {
        let pullRequest: PullRequest
        var id: String { pullRequest.id }
    }

    /// Secciones que arrancan colapsadas.
    private enum CollapsibleSection: Hashable {
        case automation
        case ignored
    }

    var body: some View {
        VStack(spacing: 0) {
            // La confirmación tapa el aviso: son el mismo lugar y nunca hacen
            // falta las dos a la vez.
            if let pendingMerge {
                confirmBar(pendingMerge)
                Divider()
            } else if let outcome = store.outcome {
                outcomeBanner(outcome)
                Divider()
            }
            content
        }
    }

    /// Confirmación inline en vez de un diálogo del sistema.
    ///
    /// Un `.confirmationDialog` dentro de un `NSPopover` tiene que negociar el
    /// foco con la ventana del panel, y el panel se cierra justamente cuando
    /// pierde el foco. Inline no hay nada que negociar.
    private func confirmBar(_ pending: PendingMerge) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.triangle.merge")
            VStack(alignment: .leading, spacing: 1) {
                Text("¿Mergear \(pending.pullRequest.shortRepository) "
                    + "#\(pending.pullRequest.number)?")
                    .font(.system(size: 10, weight: .semibold))
                // El método sale del repo: lo mostramos para que sepas qué va a
                // pasar, no para que elijas.
                Text(pending.pullRequest.defaultMergeMethod?.title ?? "método desconocido")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            Button("Cancelar") { pendingMerge = nil }
                .controlSize(.small)
            Button("Mergear") {
                store.perform(.merge, on: pending.pullRequest)
                pendingMerge = nil
            }
            .controlSize(.small)
            .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color.accentColor.opacity(0.10))
    }

    /// Aviso de la última escritura. Es la única señal de que funcionó: aprobar
    /// saca el PR de tu cola y mergear lo cierra, así que la fila desaparece.
    private func outcomeBanner(_ outcome: ReviewQueueStore.Outcome) -> some View {
        HStack(spacing: 6) {
            Image(systemName: outcome.isError
                ? "exclamationmark.triangle.fill"
                : "checkmark.circle.fill")
            Text(outcome.text)
                .lineLimit(3)
            Spacer(minLength: 4)
            Button {
                store.dismissOutcome()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
        }
        .font(.system(size: 10))
        .foregroundStyle(outcome.isError ? Color.red : Color.green)
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background((outcome.isError ? Color.red : Color.green).opacity(0.08))
    }

    // MARK: - Contenido

    @ViewBuilder
    private var content: some View {
        switch store.state {
        case .idle:
            loading
        // Si ya hay data, la mostramos mientras refresca en vez de parpadear.
        case .loading where store.pullRequests.isEmpty:
            loading
        case .failed(let message):
            centered {
                ContentUnavailableView {
                    Label("No pude leer la cola", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(message).font(.caption)
                } actions: {
                    Button("Reintentar") { store.refresh(force: true) }
                }
            }
        default:
            list
        }
    }

    private var loading: some View {
        centered { ProgressView("Consultando GitHub…").controlSize(.small) }
    }

    @ViewBuilder
    private var list: some View {
        let sections = store.humanSections
        let merge = store.readyToMerge
        if sections.isEmpty, merge.isEmpty, store.automation.isEmpty, store.ignored.isEmpty {
            centered {
                ContentUnavailableView {
                    Label("Nada pendiente", systemImage: "checkmark.circle")
                } description: {
                    Text("No hay PRs esperando tu review.")
                }
            }
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    // Primero, porque es lo que se resuelve con un click.
                    if !merge.isEmpty {
                        VStack(alignment: .leading, spacing: 5) {
                            sectionTitle("Listos para mergear", count: merge.count)
                                .padding(.horizontal, 10)
                            rows(merge)
                        }
                    }
                    ForEach(sections, id: \.bucket) { section in
                        VStack(alignment: .leading, spacing: 5) {
                            sectionTitle(
                                section.bucket.title,
                                count: section.items.count,
                                subtitle: section.bucket.subtitle
                            )
                            .padding(.horizontal, 10)
                            rows(section.items)
                        }
                    }
                    collapsible(.automation, title: "Automatización", items: store.automation)
                    collapsible(.ignored, title: "Ignorados", items: store.ignored)
                }
                .padding(.vertical, 10)
                .padding(.horizontal, 4)
            }
        }
    }

    private func rows(_ items: [PullRequest]) -> some View {
        ForEach(items) { pullRequest in
            PullRequestRow(
                pullRequest: pullRequest,
                isIgnored: store.isIgnored(pullRequest),
                isActing: store.isActing(on: pullRequest),
                behindBy: store.behindCount(for: pullRequest)
            ) { action in
                // Mergear es irreversible y afecta un repo compartido: pasa por
                // confirmación. El resto se aplica directo.
                if action.needsConfirmation {
                    pendingMerge = PendingMerge(pullRequest: pullRequest)
                } else {
                    store.perform(action, on: pullRequest)
                }
            }
        }
    }

    @ViewBuilder
    private func collapsible(
        _ section: CollapsibleSection,
        title: String,
        items: [PullRequest]
    ) -> some View {
        if !items.isEmpty {
            let isExpanded = expanded.contains(section)
            VStack(alignment: .leading, spacing: 5) {
                Button {
                    withAnimation(.easeOut(duration: 0.15)) {
                        if isExpanded { expanded.remove(section) } else { expanded.insert(section) }
                    }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.tertiary)
                        // El chevron las indenta un poco respecto de las
                        // secciones de acción, que es justo la jerarquía buscada.
                        sectionTitle(title, count: items.count, prominence: .muted)
                    }
                    .padding(.horizontal, 10)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)

                if isExpanded {
                    rows(items)
                }
            }
        }
    }

    /// Dos niveles de jerarquía: las secciones que piden algo de vos y las
    /// colapsadas, que están para consultar.
    private enum Prominence {
        case action
        case muted

        var size: CGFloat { self == .action ? 11 : 10 }
        var weight: Font.Weight { self == .action ? .bold : .semibold }
        var style: AnyShapeStyle {
            self == .action ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary)
        }
    }

    private func sectionTitle(
        _ title: String,
        count: Int,
        subtitle: String? = nil,
        prominence: Prominence = .action
    ) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 6) {
                Text(title.uppercased())
                    .font(.system(size: prominence.size, weight: prominence.weight))
                    // Sin tracking las mayúsculas se apelotonan y pierden el peso
                    // de encabezado que les estamos dando.
                    .tracking(0.7)
                    .foregroundStyle(prominence.style)
                Text("\(count)")
                    .font(.system(size: 9, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(.quaternary, in: Capsule())
                Spacer(minLength: 0)
            }
            if let subtitle {
                Text(subtitle)
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func centered<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content().frame(maxWidth: .infinity, maxHeight: .infinity)
    }

}
