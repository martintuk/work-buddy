import SwiftUI

/// Cola de PRs de la sección GitHub.
struct GitHubSectionView: View {
    let store: ReviewQueueStore
    let showRepositories: () -> Void

    @AppStorage("github.collapsedSections") private var collapsedSectionIDs = ""
    @State private var pendingAction: PendingAction?

    /// Acción sobre un PR esperando confirmación.
    struct PendingAction: Identifiable {
        let pullRequest: PullRequest
        let action: PullRequestAction
        var id: String { "\(pullRequest.id)-\(action.id)" }
    }

    /// Una identidad estable conserva el plegado cuando se actualiza la cola.
    private enum QueueSection: Hashable {
        case readyToMerge
        case needingCIFix
        case needingReply
        case review(ReviewBucket)
        case automation
        case ignored

        /// Claves de preferencias independientes de los títulos visibles.
        var persistenceID: String {
            switch self {
            case .readyToMerge: "readyToMerge"
            case .needingCIFix: "needingCIFix"
            case .needingReply: "needingReply"
            case .review(.needsReview): "needsReview"
            case .review(.approvedAlready): "approvedAlready"
            case .automation: "automation"
            case .ignored: "ignored"
            }
        }

        var symbol: String {
            switch self {
            case .readyToMerge: "arrow.triangle.merge"
            case .needingCIFix: "wrench.and.screwdriver"
            case .needingReply: "bubble.left.and.bubble.right"
            case .review(.needsReview): "eye"
            case .review(.approvedAlready): "checkmark.circle"
            case .automation: "gearshape.2"
            case .ignored: "eye.slash"
            }
        }

        var tint: Color {
            switch self {
            case .readyToMerge: .green
            case .needingCIFix: .red
            case .needingReply: .orange
            case .review(.needsReview): .blue
            case .review(.approvedAlready): .teal
            case .automation: .cyan
            case .ignored: .gray
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Button(action: showRepositories) {
                HStack(spacing: 6) {
                    Label("Repositorios", systemImage: store.repositoryFilter.isActive
                        ? "line.3.horizontal.decrease.circle.fill"
                        : "line.3.horizontal.decrease.circle")
                        .foregroundStyle(store.repositoryFilter.isActive ? Color.accentColor : Color.primary)
                    Spacer()
                    Text(store.repositoryFilter.isActive ? "Filtro activo" : "Todos")
                        .foregroundStyle(.secondary)
                    Image(systemName: "chevron.right")
                        .foregroundStyle(.secondary)
                }
                .font(.system(size: 11))
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Color.accentColor.opacity(store.repositoryFilter.isActive ? 0.08 : 0))
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .help("Filtrar repositorios de GitHub")
            Divider()

            // La confirmación tapa el aviso: son el mismo lugar y nunca hacen
            // falta las dos a la vez.
            if let pendingAction {
                confirmBar(pendingAction)
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
    private func confirmBar(_ pending: PendingAction) -> some View {
        HStack(spacing: 8) {
            Image(systemName: pending.action.systemImage)
            VStack(alignment: .leading, spacing: 1) {
                Text(confirmationTitle(for: pending))
                    .font(.system(size: 10, weight: .semibold))
                if let detail = confirmationDetail(for: pending) {
                    Text(detail)
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            Button("Cancelar") { pendingAction = nil }
                .controlSize(.small)
            Button("Confirmar") {
                store.perform(pending.action, on: pending.pullRequest)
                pendingAction = nil
            }
            .controlSize(.small)
            .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color.accentColor.opacity(0.10))
    }

    private func confirmationTitle(for pending: PendingAction) -> String {
        switch pending.action {
        case .dependabotRebase:
            "¿Rebasear \(pending.pullRequest.shortRepository) "
                + "#\(pending.pullRequest.number) con Dependabot?"
        case .merge:
            "¿Mergear \(pending.pullRequest.shortRepository) "
                + "#\(pending.pullRequest.number)?"
        default:
            "¿\(pending.action.title) \(pending.pullRequest.shortRepository) "
                + "#\(pending.pullRequest.number)?"
        }
    }

    private func confirmationDetail(for pending: PendingAction) -> String? {
        switch pending.action {
        case .dependabotRebase:
            "@dependabot rebase · puede reemplazar el PR"
        case .merge:
            // El método sale del repo: lo mostramos para que sepas qué va a
            // pasar, no para que elijas.
            pending.pullRequest.defaultMergeMethod?.title ?? "método desconocido"
        default:
            nil
        }
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

    private var hasVisiblePullRequests: Bool {
        !store.humanSections.isEmpty || !store.readyToMerge.isEmpty || !store.needingCIFix.isEmpty
            || !store.needingReply.isEmpty || !store.automation.isEmpty || !store.ignored.isEmpty
    }

    @ViewBuilder
    private var content: some View {
        switch store.state {
        case .idle:
            loading
        // Mostramos lo que ya llegó, pero no un estado vacío con colas pendientes.
        case .loading where !hasVisiblePullRequests:
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
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                // Reservamos el estado general vacío para cuando se oculten las categorías vacías.
                if !hasVisiblePullRequests && store.hasRepositoryFilteredResults {
                    centered {
                        ContentUnavailableView {
                            Label(store.hasRepositoryFilteredResults ? "Sin PRs con este filtro" : "Nada pendiente",
                                  systemImage: store.hasRepositoryFilteredResults ? "line.3.horizontal.decrease.circle" : "checkmark.circle")
                        } description: {
                            Text(store.hasRepositoryFilteredResults
                                ? "Hay resultados en repositorios ocultos. Podés cambiar el filtro o ver todos."
                                : "No hay PRs esperando tu review.")
                        } actions: {
                            if store.repositoryFilter.isActive {
                                Button("Ver todos") { store.clearRepositoryFilter() }
                            }
                        }
                    }
                }
                // Primero, porque es lo que se resuelve con un click.
                queueSection(.readyToMerge, title: "Para mergear", items: merge)
                queueSection(.needingCIFix, title: "Para Fixear", items: store.needingCIFix)
                queueSection(.needingReply, title: "Para responder", items: store.needingReply)
                ForEach(ReviewBucket.allCases, id: \.self) { bucket in
                    queueSection(
                        .review(bucket),
                        title: bucket.title,
                        subtitle: bucket.subtitle,
                        items: sections.first { $0.bucket == bucket }?.items ?? []
                    )
                }
                queueSection(.automation, title: "Automatización", items: store.automation)
                queueSection(.ignored, title: "Ignorados", items: store.ignored)
            }
            .padding(10)
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
                // Tanto las acciones locales como las de GitHub se confirman.
                if action.needsConfirmation {
                    pendingAction = PendingAction(
                        pullRequest: pullRequest,
                        action: action
                    )
                } else {
                    store.perform(action, on: pullRequest)
                }
            }
        }
    }

    @ViewBuilder
    private func queueSection(
        _ section: QueueSection,
        title: String,
        subtitle: String? = nil,
        items: [PullRequest]
    ) -> some View {
        let collapsed = Set(collapsedSectionIDs.split(separator: ",").map(String.init))
        let isExpanded = !collapsed.contains(section.persistenceID)
        VStack(alignment: .leading, spacing: 4) {
            QueueSectionHeader(
                title: title,
                subtitle: subtitle,
                symbol: section.symbol,
                tint: section.tint,
                count: items.count,
                isExpanded: isExpanded,
                accessibilityItemName: "pull requests"
            ) {
                withAnimation(.easeInOut(duration: 0.18)) {
                    var updated = collapsed
                    if isExpanded {
                        updated.insert(section.persistenceID)
                    } else {
                        updated.remove(section.persistenceID)
                    }
                    collapsedSectionIDs = updated.sorted().joined(separator: ",")
                }
            }

            if isExpanded {
                rows(items)
            }
        }
    }

    private func centered<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content().frame(maxWidth: .infinity, maxHeight: .infinity)
    }

}

/// Todas las categorías comparten tamaño, contraste y área de interacción.
struct QueueSectionHeader: View {
    let title: String
    let subtitle: String?
    let symbol: String
    let tint: Color
    let count: Int
    let isExpanded: Bool
    let accessibilityItemName: String
    let toggle: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 9) {
                Image(systemName: symbol)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 28, height: 28)
                    .background(tint.opacity(0.13), in: RoundedRectangle(cornerRadius: 7))

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.primary)
                    if let subtitle {
                        Text(subtitle)
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Text("\(count)")
                    .font(.system(size: 10, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(tint.opacity(0.13), in: Capsule())

                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .frame(width: 12)
            }
            .padding(.horizontal, 10)
            .frame(height: 46)
            .background(tint.opacity(isHovering ? 0.13 : 0.07), in: RoundedRectangle(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(tint.opacity(isHovering ? 0.35 : 0.2), lineWidth: 1)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityLabel("\(title), \(count) \(accessibilityItemName)")
        .accessibilityValue(isExpanded ? "Expandido" : "Contraído")
        .accessibilityHint(isExpanded ? "Ocultar la sección" : "Mostrar la sección")
        .help(isExpanded ? "Ocultar \(title)" : "Mostrar \(title)")
    }
}

/// Presentación de las categorías; las reglas viven en PullRequestQueuePolicy.
extension ReviewBucket {
    var title: String {
        switch self {
        case .needsReview: "Para revisar"
        case .approvedAlready: "Ya aprobados"
        }
    }

    var subtitle: String? {
        switch self {
        case .needsReview: nil
        case .approvedAlready: "tu review es opcional, ya tienen los approvals"
        }
    }
}
