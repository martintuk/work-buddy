import SwiftUI

/// Cola de PRs de la sección GitHub.
struct GitHubSectionView: View {
    let store: ReviewQueueStore
    var showsExecutionControls = true
    let showRepositories: () -> Void

    @AppStorage("appearance.showEmptySections") private var showEmptySections = true
    @AppStorage("actions.autoConfirm") private var autoConfirmActions = false
    @AppStorage("github.collapsedSections") private var collapsedSectionIDs = ""
    @State private var pendingAction: PendingPullRequestAction?
    @State private var configurationHint: ConfigurationHint?
    @State private var selectedPullRequestID: String?

    private enum ConfigurationHint {
        case editor
        case agent
        case folder(String)
    }

    /// Una identidad estable conserva el plegado cuando se actualiza la cola.
    private enum QueueSection: Hashable {
        case readyToMerge
        case needingCIFix
        case needingRebase
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
            case .automation:
                L10n.text(.githubAutomationHelp)
            default:
                nil
            }
        }

        /// Claves de preferencias independientes de los títulos visibles.
        var persistenceID: String {
            switch self {
            case .readyToMerge: "readyToMerge"
            case .needingCIFix: "needingCIFix"
            case .needingRebase: "needingRebase"
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
            case .needingRebase: "arrow.triangle.branch"
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
            case .needingRebase: .purple
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
            filters
            Divider()
            content
                .overlay(alignment: .top) {
                    topNotice
                        .padding(.horizontal, 10)
                        .padding(.top, 8)
                }
            if showsExecutionControls {
                PullRequestExecutionControls(store: store)
            }
        }
        .onChange(of: store.editor.selectedURL) { _, selectedURL in
            if selectedURL != nil, case .editor = configurationHint { configurationHint = nil }
        }
        .onChange(of: store.agentCLI.isConfigured) { _, isConfigured in
            if isConfigured, case .agent = configurationHint { configurationHint = nil }
        }
        .onChange(of: pendingAction.map { store.isAvailable($0) } ?? false) { _, available in
            if !available { pendingAction = nil }
        }

    }

    private var filters: some View {
        HStack(spacing: 8) {
            Button(action: showRepositories) {
                filterLabel(L10n.text(.repositoriesTitle), symbol: "folder",
                            active: store.repositoryFilter.isActive)
            }
            .buttonStyle(.plain)
            // El selector compacto deja el espacio restante al filtro de automatización.
            .fixedSize(horizontal: true, vertical: false)
            .help(L10n.text(.repositoriesFilterHelp))
            .accessibilityLabel(L10n.text(.repositoriesFilterHelp))
            .accessibilityValue(L10n.text(store.repositoryFilter.isActive ? .repositoriesFilterActive : .repositoriesAll))

            Menu {
                Picker(L10n.text(.githubAutomation), selection: Binding(
                    get: { store.automationFilter },
                    set: { store.setAutomationFilter($0) }
                )) {
                    ForEach(AutomationFilter.allCases, id: \.self) { filter in
                        Text(filter.title).tag(filter)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } label: {
                filterLabel(store.automationFilter.title, symbol: "line.3.horizontal.decrease",
                            active: store.automationFilter.isActive)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .frame(maxWidth: .infinity)
            .help(L10n.text(.automationFilterHelp))
            .accessibilityLabel(L10n.text(.automationFilterHelp))
            .accessibilityValue(store.automationFilter.title)
            Button {
                pendingAction = nil
                configurationHint = nil
                store.toggleBatchSelection()
            } label: {
                Image(systemName: store.batch.isSelecting ? "checkmark.square.fill" : "checkmark.square")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(store.batch.isSelecting ? Color.accentColor : Color.secondary)
                    .frame(width: 28, height: 26)
                    .background(Color.accentColor.opacity(store.batch.isSelecting ? 0.12 : 0.05), in: RoundedRectangle(cornerRadius: 7))
            }
            .buttonStyle(.plain)
            .disabled(store.autopilot.isActive || store.batch.isRunning || (!store.batch.isSelecting && (store.viewerLogin == nil || store.batchCandidates.isEmpty)))
            .help(L10n.text(store.batch.isSelecting ? .batchExitSelection : .batchSelect))
            .accessibilityLabel(L10n.text(store.batch.isSelecting ? .batchExitSelection : .batchSelect))
            Button {
                pendingAction = nil
                configurationHint = nil
                store.toggleAutopilot()
            } label: {
                Image(systemName: store.autopilot.isPresented ? "bolt.fill" : "bolt")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(store.autopilot.isPresented ? Color.accentColor : Color.secondary)
                    .frame(width: 28, height: 26)
                    .background(Color.accentColor.opacity(store.autopilot.isPresented ? 0.12 : 0.05), in: RoundedRectangle(cornerRadius: 7))
            }
            .buttonStyle(.plain)
            .disabled(store.batch.isRunning || store.autopilot.isActive || (!store.autopilot.isPresented && store.viewerLogin == nil))
            .help(L10n.text(store.autopilot.isPresented ? .autopilotClose : .autopilotOpen))
            .accessibilityLabel(L10n.text(store.autopilot.isPresented ? .autopilotClose : .autopilotOpen))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
    }

    /// Ambos controles comparten el aspecto aunque abran destinos distintos.
    private func filterLabel(_ title: String, symbol: String, active: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .frame(width: 14)
            Text(title)
                .lineLimit(1)
            Spacer(minLength: 4)
            Image(systemName: "chevron.down")
                .font(.system(size: 8, weight: .semibold))
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(active ? Color.accentColor : Color.secondary)
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity)
        .frame(height: 26)
        .background(Color.accentColor.opacity(active ? 0.12 : 0.05), in: Capsule())
        .overlay {
            Capsule().strokeBorder(active ? Color.accentColor.opacity(0.25) : Color.secondary.opacity(0.15))
        }
        .contentShape(.capsule)
    }

    /// Los avisos flotan sobre la lista para no alterar su altura ni el scroll.
    @ViewBuilder
    private var topNotice: some View {
        Group {
            // La confirmación tapa el aviso: son el mismo lugar y nunca hacen
            // falta las dos a la vez.
            if let warning = store.projectOpener.warning {
                branchWarning(warning)
            } else if let pendingAction, store.isAvailable(pendingAction),
                      let pullRequest = store.currentPullRequest(id: pendingAction.pullRequestID) {
                confirmBar(pendingAction, pullRequest: pullRequest)
            } else if let message = configurationHintMessage {
                configurationNotice(message)
            }
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .shadow(color: .black.opacity(0.12), radius: 5, y: 2)
    }

    private var configurationHintMessage: String? {
        switch configurationHint {
        case .editor where store.editor.selectedURL == nil:
            L10n.text(.editorSelectInSettings)
        case .agent:
            store.agentCLI.configurationMessage
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
            Button(warning.target == .agent ? store.agentCLI.openTitle : L10n.text(.editorOpenProject)) {
                Task { await store.openProjectWithoutBranch() }
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
    private func confirmBar(_ pending: PendingPullRequestAction, pullRequest: PullRequest) -> some View {
        HStack(spacing: 8) {
            Image(systemName: pending.action.systemImage)
            VStack(alignment: .leading, spacing: 1) {
                Text(confirmationTitle(for: pending, pullRequest: pullRequest))
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
                guard store.isAvailable(pending) else {
                    pendingAction = nil
                    return
                }
                store.perform(pending.action, onID: pending.pullRequestID)
                pendingAction = nil
            }
            .controlSize(.small)
            .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color.accentColor.opacity(0.10))
    }

    private func confirmationTitle(for pending: PendingPullRequestAction, pullRequest: PullRequest) -> String {
        let repository = pullRequest.shortRepository
        let number = String(pullRequest.number)
        if pending.action == .dependabotRebase {
            return L10n.text(.confirmDependabot, repository, number)
        }
        return L10n.text(.confirmAction, pending.action.title, repository, number)
    }

    private func confirmationDetail(for pending: PendingPullRequestAction) -> String? {
        switch pending.action {
        case .dependabotRebase:
            L10n.text(.githubDependabotWarning)
        case .merge:
            // El método sale del repo: lo mostramos para que sepas qué va a
            // pasar, no para que elijas.
            pending.mergeMethod?.title ?? L10n.text(.githubUnknownMergeMethod)
        default:
            nil
        }
    }

    // MARK: - Contenido

    private var hasVisiblePullRequests: Bool {
        !store.reviewSections.isEmpty || !store.readyToMerge.isEmpty || !store.needingCIFix.isEmpty
            || !store.needingRebase.isEmpty || !store.needingReply.isEmpty || !store.waitingForReply.isEmpty || !store.automation.isEmpty || !store.ignored.isEmpty
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
        let sections = store.reviewSections
        let merge = store.readyToMerge
        ScrollView {
            // En macOS 26, las actualizaciones de esta cola pueden dejar al
            // LazyVStack con headers fijos recalculando posiciones sin terminar
            // (LazySubviewPlacements), bloqueando el hilo principal. La pila
            // eager evita ese ciclo; los encabezados se desplazan con las filas.
            VStack(alignment: .leading, spacing: 0) {
                if !hasVisiblePullRequests && (!showEmptySections || store.hasFilteredResults) {
                    centered {
                        ContentUnavailableView {
                            Label(store.hasFilteredResults ? L10n.text(.repositoriesFilteredEmpty) : L10n.text(.commonNothingPending),
                                  systemImage: store.hasFilteredResults ? "line.3.horizontal.decrease.circle" : "checkmark.circle")
                        } description: {
                            if !store.hasFilteredResults { Text(L10n.text(.githubNoReviews)) }
                        } actions: {
                            if store.hasActiveFilters {
                                Button(L10n.text(.repositoriesShowAll)) { store.clearFilters() }
                            }
                        }
                    }
                }
                // Primero, porque es lo que se resuelve con un click.
                queueSection(.readyToMerge, title: L10n.text(.githubMerge), items: merge)
                queueSection(.needingCIFix, title: L10n.text(.githubFix), items: store.needingCIFix)
                queueSection(.needingRebase, title: L10n.text(.githubRebase), items: store.needingRebase)
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
                queueSection(.automation, title: L10n.text(.githubAutomationNotReady), items: store.automation)
                queueSection(.ignored, title: L10n.text(.githubIgnored), items: store.ignored)
            }
            .padding(.horizontal, QueueLayout.sectionSpacing)
            .padding(.bottom, QueueLayout.sectionSpacing)
        }
    }

    private func rows(_ items: [PullRequest], in section: QueueSection) -> some View {
        ForEach(items.map { QueueSectionItem(section: section.persistenceID, item: $0) }) { entry in
            let pullRequest = entry.item
            PullRequestRow(
                pullRequest: pullRequest,
                isSelected: store.batch.isSelecting ? store.batch.selectedIDs.contains(pullRequest.id)
                    : selectedPullRequestID == pullRequest.id,
                select: { selectedPullRequestID = pullRequest.id },
                isIgnored: store.isIgnored(pullRequest),
                isActing: store.isActing(on: pullRequest),
                behindBy: store.behindCount(for: pullRequest),
                localFolder: store.localRepositories.folder(for: pullRequest.repository),
                editor: store.editor,
                agentCLI: store.agentCLI,
                requestEditorConfiguration: {
                    pendingAction = nil
                    store.projectOpener.dismissNotice()
                    configurationHint = .editor
                },
                requestFolderConfiguration: {
                    pendingAction = nil
                    store.projectOpener.dismissNotice()
                    configurationHint = .folder(pullRequest.repository)
                },
                isOpeningProject: store.projectOpener.openingID == pullRequest.id || store.agentCLI.openingID == pullRequest.id,
                canOpenProject: !store.projectOpener.isOpening && !store.agentCLI.isOpening,
                openProject: {
                    guard let folder = store.localRepositories.folder(for: pullRequest.repository) else { return }
                    pendingAction = nil
                    configurationHint = nil
                    Task {
                        await store.openProject(pullRequest, folder: folder)
                    }
                },
                openAgent: {
                    pendingAction = nil
                    configurationHint = nil
                    store.projectOpener.dismissNotice()
                    store.agentCLI.dismissError()
                    guard let folder = store.localRepositories.folder(for: pullRequest.repository) else {
                        configurationHint = .folder(pullRequest.repository)
                        return
                    }
                    guard store.agentCLI.isConfigured else {
                        configurationHint = .agent
                        return
                    }
                    Task { await store.openAgent(pullRequest, folder: folder) }
                },
                repositoryStore: store,
                batchSelection: store.batch.isSelecting ? PullRequestBatchSelection(
                    isSelected: store.batch.selectedIDs.contains(pullRequest.id),
                    canSelect: !store.batch.isRunning && store.batch.candidates.contains { $0.id == pullRequest.id },
                    toggle: { store.batch.toggle(pullRequest.id) }
                ) : nil
            ) { action in
                configurationHint = nil
                store.projectOpener.dismissNotice()
                if action.needsConfirmation && !autoConfirmActions {
                    guard let current = store.currentPullRequest(id: pullRequest.id) else { return }
                    let pending = PendingPullRequestAction(action: action, pullRequest: current)
                    pendingAction = store.isAvailable(pending) ? pending : nil
                } else {
                    pendingAction = nil
                    store.perform(action, onID: pullRequest.id)
                }
            }
            .padding(.top, QueueLayout.rowSpacing)
            .id(entry.id)
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
            Section {
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
                            .padding(.top, QueueLayout.rowSpacing)
                    }
                    rows(items, in: section)
                }
            } header: {
                HStack(spacing: 5) {
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
                }
            }
        }
    }

    private func centered<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content().frame(maxWidth: .infinity, maxHeight: .infinity)
    }

}

enum QueueLayout {
    static let sectionSpacing: CGFloat = 10
    static let rowSpacing: CGFloat = 4
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
        // El margen viaja con el encabezado para conservarlo al fijarse al techo.
        .padding(.top, QueueLayout.sectionSpacing)
        // El fondo opaco evita que las filas se vean detrás del encabezado fijo.
        .background(Color(nsColor: .windowBackgroundColor))
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

/// El panel también mantiene estos controles accesibles al navegar o ampliar Actividad.
struct PullRequestExecutionControls: View {
    let store: ReviewQueueStore
    var compact = false

    var body: some View {
        if store.autopilot.isPresented {
            PullRequestAutopilotBar(autopilot: store.autopilot, setEnabled: store.setAutopilotEnabled, compact: compact)
        } else if store.batch.isSelecting {
            PullRequestBatchBar(batch: store.batch) { store.startBatch($0) }
        }
    }
}
