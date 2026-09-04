import SwiftUI

/// Cola de PRs de la sección GitHub.
struct GitHubSectionView: View {
    let store: ReviewQueueStore
    let showRepositories: () -> Void
    let showAgentConfiguration: () -> Void

    @AppStorage("appearance.showEmptySections") private var showEmptySections = true
    @AppStorage("github.collapsedSections") private var collapsedSectionIDs = ""
    @State private var pendingAction: PendingAction?
    @State private var configurationHint: ConfigurationHint?

    private enum ConfigurationHint {
        case editor
        case folder(String)
    }

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
        case waitingForReply
        case review(ReviewBucket)
        case automation
        case ignored

        var summary: String? {
            switch self {
            case .needingReply:
                L10n.text(.githubReplyHelp)
            case .waitingForReply:
                L10n.text(.githubWaitingHelp)
            default:
                nil
            }
        }

        /// Claves de preferencias independientes de los títulos visibles.
        var persistenceID: String {
            switch self {
            case .readyToMerge: "readyToMerge"
            case .needingCIFix: "needingCIFix"
            case .needingReply: "needingReply"
            case .waitingForReply: "waitingForReply"
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
            case .needingReply, .waitingForReply: "bubble.left.and.bubble.right"
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
            case .waitingForReply: .gray
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
                    Label(L10n.text(.repositoriesTitle), systemImage: store.repositoryFilter.isActive
                        ? "line.3.horizontal.decrease.circle.fill"
                        : "line.3.horizontal.decrease.circle")
                        .foregroundStyle(store.repositoryFilter.isActive ? Color.accentColor : Color.primary)
                    Spacer()
                    Text(store.repositoryFilter.isActive ? L10n.text(.repositoriesFilterActive) : L10n.text(.repositoriesAll))
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
            .help(L10n.text(.repositoriesFilterHelp))
            Divider()

            // La confirmación tapa el aviso: son el mismo lugar y nunca hacen
            // falta las dos a la vez.
            if let error = store.agentCLI.error {
                projectError(error, dismiss: store.agentCLI.dismissError)
                Divider()
            } else if let warning = store.projectOpener.warning {
                branchWarning(warning)
                Divider()
            } else if let error = store.projectOpener.error {
                projectError(error, dismiss: store.projectOpener.dismissNotice)
                Divider()
            } else if let pendingAction {
                confirmBar(pendingAction)
                Divider()
            } else if let message = configurationHintMessage {
                configurationNotice(message)
                Divider()
            } else if let outcome = store.outcome {
                outcomeBanner(outcome)
                Divider()
            }
            content
        }
        .onChange(of: store.editor.selectedURL) { _, selectedURL in
            if selectedURL != nil, case .editor = configurationHint { configurationHint = nil }
        }
    }

    private var configurationHintMessage: String? {
        switch configurationHint {
        case .editor where store.editor.selectedURL == nil:
            L10n.text(.editorSelectInSettings)
        case .folder(let repository) where store.localRepositories.folder(for: repository) == nil:
            L10n.text(.editorAssociateFolderInRepositories, repository)
        default:
            nil
        }
    }

    private func branchWarning(_ warning: ProjectOpener.Warning) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(warning.text)
                .fixedSize(horizontal: false, vertical: true)
                .help(warning.reason.localizedDescription)
            Spacer(minLength: 0)
            Button(L10n.text(.editorOpenProject)) {
                Task { await store.projectOpener.openWithoutBranch { try await store.editor.open($0) } }
            }
            .controlSize(.small)
            .buttonStyle(.borderedProminent)
            dismissProjectNoticeButton
        }
        .font(.system(size: 10))
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.16))
    }

    private func projectError(_ error: Error, dismiss: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
            Text(error.localizedDescription).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button(action: dismiss) { Image(systemName: "xmark") }
                .buttonStyle(.borderless)
                .help(L10n.text(.commonCancel))
                .accessibilityLabel(L10n.text(.commonCancel))
        }
        .font(.system(size: 10))
        .foregroundStyle(.red)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color.red.opacity(0.08))
    }

    private var dismissProjectNoticeButton: some View {
        Button { store.projectOpener.dismissNotice() } label: { Image(systemName: "xmark") }
            .buttonStyle(.borderless)
            .help(L10n.text(.commonCancel))
            .accessibilityLabel(L10n.text(.commonCancel))
    }

    private func configurationNotice(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "info.circle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Button { configurationHint = nil } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .help(L10n.text(.commonCancel))
            .accessibilityLabel(L10n.text(.commonCancel))
        }
        .font(.system(size: 10))
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.16))
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
            Button(L10n.text(.commonCancel)) { pendingAction = nil }
                .controlSize(.small)
            Button(L10n.text(.commonConfirm)) {
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
        let repository = pending.pullRequest.shortRepository
        let number = String(pending.pullRequest.number)
        if pending.action == .dependabotRebase {
            return L10n.text(.confirmDependabot, repository, number)
        }
        return L10n.text(.confirmAction, pending.action.title, repository, number)
    }

    private func confirmationDetail(for pending: PendingAction) -> String? {
        switch pending.action {
        case .dependabotRebase:
            L10n.text(.githubDependabotWarning)
        case .merge:
            // El método sale del repo: lo mostramos para que sepas qué va a
            // pasar, no para que elijas.
            pending.pullRequest.defaultMergeMethod?.title ?? L10n.text(.githubUnknownMergeMethod)
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
            || !store.needingReply.isEmpty || !store.waitingForReply.isEmpty || !store.automation.isEmpty || !store.ignored.isEmpty
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
                    Label(L10n.text(.githubLoadFailed), systemImage: "exclamationmark.triangle")
                } description: {
                    Text(message.text).font(.caption)
                } actions: {
                    Button(L10n.text(.commonRetry)) { store.refresh(force: true) }
                }
            }
        default:
            list
        }
    }

    private var loading: some View {
        centered { ProgressView(L10n.text(.githubLoading)).controlSize(.small) }
    }

    @ViewBuilder
    private var list: some View {
        let sections = store.humanSections
        let merge = store.readyToMerge
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if !hasVisiblePullRequests && (!showEmptySections || store.hasRepositoryFilteredResults) {
                    centered {
                        ContentUnavailableView {
                            Label(store.hasRepositoryFilteredResults ? L10n.text(.repositoriesFilteredEmpty) : L10n.text(.commonNothingPending),
                                  systemImage: store.hasRepositoryFilteredResults ? "line.3.horizontal.decrease.circle" : "checkmark.circle")
                        } description: {
                            Text(store.hasRepositoryFilteredResults
                                ? L10n.text(.repositoriesHiddenResults)
                                : L10n.text(.githubNoReviews))
                        } actions: {
                            if store.repositoryFilter.isActive {
                                Button(L10n.text(.repositoriesShowAll)) { store.clearRepositoryFilter() }
                            }
                        }
                    }
                }
                // Primero, porque es lo que se resuelve con un click.
                queueSection(.readyToMerge, title: L10n.text(.githubMerge), items: merge)
                queueSection(.needingCIFix, title: L10n.text(.githubFix), items: store.needingCIFix)
                queueSection(.needingReply, title: L10n.text(.githubReply), items: store.needingReply)
                queueSection(.waitingForReply, title: L10n.text(.githubWaiting), items: store.waitingForReply)
                ForEach(ReviewBucket.allCases, id: \.self) { bucket in
                    queueSection(
                        .review(bucket),
                        title: bucket.title,
                        subtitle: bucket.subtitle,
                        items: sections.first { $0.bucket == bucket }?.items ?? []
                    )
                }
                queueSection(.automation, title: L10n.text(.githubAutomation), items: store.automation)
                queueSection(.ignored, title: L10n.text(.githubIgnored), items: store.ignored)
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
                behindBy: store.behindCount(for: pullRequest),
                localFolder: store.localRepositories.folder(for: pullRequest.repository),
                editor: store.editor,
                requestEditorConfiguration: {
                    pendingAction = nil
                    store.projectOpener.dismissNotice()
                    store.dismissOutcome()
                    configurationHint = .editor
                },
                requestFolderConfiguration: {
                    pendingAction = nil
                    store.projectOpener.dismissNotice()
                    store.dismissOutcome()
                    configurationHint = .folder(pullRequest.repository)
                },
                isOpeningProject: store.projectOpener.openingID == pullRequest.id || store.agentCLI.openingID == pullRequest.id,
                canOpenProject: !store.projectOpener.isOpening && !store.agentCLI.isOpening,
                openProject: {
                    guard let folder = store.localRepositories.folder(for: pullRequest.repository) else { return }
                    pendingAction = nil
                    configurationHint = nil
                    store.dismissOutcome()
                    Task {
                        await store.projectOpener.open(.init(pullRequest: pullRequest, folder: folder)) {
                            try await store.editor.open($0)
                        }
                    }
                },
                openAgent: {
                    pendingAction = nil
                    configurationHint = nil
                    store.projectOpener.dismissNotice()
                    store.dismissOutcome()
                    guard let folder = store.localRepositories.folder(for: pullRequest.repository) else {
                        showRepositories()
                        return
                    }
                    guard store.agentCLI.isConfigured else {
                        showAgentConfiguration()
                        return
                    }
                    Task { await store.agentCLI.open(folder, id: pullRequest.id) }
                }
            ) { action in
                configurationHint = nil
                store.projectOpener.dismissNotice()
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
        if showEmptySections || !items.isEmpty {
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
                    accessibilityItemName: L10n.text(.githubPullRequests)
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
                    if let summary = section.summary {
                        Text(summary)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .background(section.tint.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
                    }
                    rows(items)
                }
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
        .accessibilityValue(isExpanded ? L10n.text(.sectionExpanded) : L10n.text(.sectionCollapsed))
        .accessibilityHint(isExpanded ? L10n.text(.sectionHide) : L10n.text(.sectionShow))
        .help(isExpanded ? L10n.text(.sectionHideTitle, title) : L10n.text(.sectionShowTitle, title))
    }
}

/// Presentación de las categorías; las reglas viven en PullRequestQueuePolicy.
extension ReviewBucket {
    var title: String {
        switch self {
        case .needsReview: L10n.text(.githubReview)
        case .approvedAlready: L10n.text(.githubApproved)
        }
    }

    var subtitle: String? {
        switch self {
        case .needsReview: nil
        case .approvedAlready: L10n.text(.githubApprovedHelp)
        }
    }
}
