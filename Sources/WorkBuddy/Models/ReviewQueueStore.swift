import AppKit
import Foundation

/// Estado de la cola de review que consume el panel.
@MainActor
@Observable
final class ReviewQueueStore {
    enum State {
        case idle
        case loading
        case loaded
        case failed(LocalizedMessage)
    }

    /// Pasado este tiempo, abrir el panel dispara un refresh.
    private static let staleAfter: TimeInterval = 120

    private(set) var state: State = .idle
    private(set) var configuration = AppConfiguration.load()
    private(set) var repositoryFilter = RepositoryFilter.load()
    private(set) var automationFilter = AutomationFilter.load()
    let localRepositories = LocalRepositoryStore()
    let editor = EditorStore()
    let agentCLI = AgentCLIStore()
    let projectOpener = ProjectOpener()
    let batch: PullRequestBatch
    let autopilot = PullRequestAutopilot()

    let activity = ActivityLog()

    init(batch: PullRequestBatch = PullRequestBatch(runner: .shared)) {
        self.batch = batch
        batch.onActivity = { [activity] in activity.record($0, source: .batch) }
        autopilot.onActivity = { [activity] in activity.record($0, source: .autopilot) }
    }
    private(set) var viewerLogin: String?
    private(set) var pullRequests: [PullRequest] = []
    /// PRs de dependabot en la cola de review, agrupados según su CI.
    /// Los que están para mergear llegan por `mergeCandidates`.
    private(set) var dependabotPullRequests: [PullRequest] = []
    /// Candidatos a merge. Vienen de otra query porque pedirle a GitHub que
    /// calcule la mergeabilidad de toda la cola de review es caro.
    private var requestedMergeCandidates: [PullRequest] = []
    private var teamDependabotPullRequests: [PullRequest] = []
    var mergeCandidates: [PullRequest] {
        (requestedMergeCandidates + teamDependabotPullRequests).uniquedByID()
    }
    private(set) var teamDependabotFailure: LocalizedMessage?
    private(set) var isLoadingTeamDependabot = false
    private var forceTeamDiscovery = false

    func retryTeamDependabot() {
        forceTeamDiscovery = true
        refresh(force: true)
    }
    /// PRs propios; se consultan aparte aunque no esperen review ni puedan mergearse.
    private(set) var fixCandidates: [PullRequest] = []
    private(set) var replyCandidates: [PullRequest] = []
    private(set) var waitingReplyCandidates: [PullRequest] = []
    private(set) var lastUpdated: Date?

    /// `behindBy` por id de PR. Un id **ausente** es "no medido", que no es lo
    /// mismo que `0` = "al día": si los confundimos, el rebase pasa a ser una
    /// adivinanza.
    private(set) var behindCounts: [String: Int] = [:]

    /// Ids de PRs con una escritura en curso.
    private(set) var inFlightActions: Set<String> = []

    /// La barra de menú es AppKit y no participa de la observación de SwiftUI,
    /// así que le avisamos por acá cuándo repintar el badge.
    var onChange: (() -> Void)?

    let notifier = Notifier()
    private let notificationTracker = PullRequestNotificationTracker()
    private let ignoreList = IgnoreList()
    private var inFlight: Task<Void, Never>?
    /// Incluye la medición de ramas que continúa después de publicar las colas.
    var isRefreshing: Bool { inFlight != nil }
    /// Una acción durante una consulta necesita otra lectura al terminar.
    private var hasPendingRefresh = false
    /// Invalida resultados de una consulta que empezó con otra configuración.
    private var configurationRevision = 0
    private var actionEffects = PullRequestActionEffects()

    // MARK: - Vistas de la data
    //
    // La lógica vive en Domain/PullRequestQueuePolicy.swift y se puede probar
    // sin instanciar el store.

    /// La cola completa, incluyendo Dependabot por ownership. Esa ampliación
    /// puede solaparse con los pedidos de review, por eso deduplicamos por id.
    private var reviewQueue: [PullRequest] {
        (pullRequests + dependabotPullRequests + teamDependabotPullRequests).uniquedByID()
    }

    /// Todo lo visible sale de acá: los ignorados se filtran una sola vez, así
    /// no hay forma de que el badge cuente algo que el panel no muestra.
    private var visible: [PullRequest] {
        filtered(reviewQueue).excluding(ignoreList.ids)
            .excludingMergeableAutomation(in: mergeCandidates)
    }

    var repositories: [RepositoryFilter.Repository] {
        repositoryFilter.repositories(in: allKnown, including: localRepositories.repositories)
    }

    var hasActiveFilters: Bool {
        repositoryFilter.isActive || automationFilter.isActive
    }

    var hasFilteredResults: Bool {
        allKnown.contains { !repositoryFilter.includes($0.repository) || !automationFilter.includes($0) }
    }

    private func filtered(_ pullRequests: [PullRequest]) -> [PullRequest] {
        automationFilter.apply(to: repositoryFilter.apply(to: pullRequests))
    }

    var reviewSections: [(bucket: ReviewBucket, items: [PullRequest])] {
        visible.reviewSections.map { section in
            (section.bucket, repositoryFilter.prioritizingFavorites(in: section.items))
        }
    }

    var automation: [PullRequest] {
        repositoryFilter.prioritizingFavorites(in: visible.automation)
    }

    var awaitingYourReview: [PullRequest] { visible.awaitingYourReview }

    var batchCandidates: [PullRequestBatch.Candidate] {
        PullRequestBatch.candidates(reviews: reviewSections.first { $0.bucket == .needsReview }?.items ?? [], merges: readyToMerge)
            .filter { !inFlightActions.contains($0.id) || batch.runningIDs.contains($0.id) || autopilot.current?.id == $0.id }
    }

    func toggleBatchSelection() {
        guard !autopilot.isActive, !batch.isRunning else { return }
        autopilot.close()
        if batch.isSelecting { batch.exit() }
        else if let viewerLogin { batch.enter(batchCandidates, viewer: viewerLogin) }
    }

    func reconcileBatch() {
        batch.reconcile(batchCandidates, viewer: viewerLogin ?? "")
        autopilot.reconcile(batchCandidates, viewer: viewerLogin ?? "")
    }

    func startBatch(_ action: PullRequestBatchAction) {
        reconcileBatch()
        guard !autopilot.isActive, !batch.isRunning, let viewerLogin, batch.viewer == viewerLogin else { return }
        let ids = Set(batch.selected(action).map(\.id))
        guard !ids.isEmpty, ids.isDisjoint(with: inFlightActions) else { return }
        let revision = configurationRevision
        let machineAccounts = configuration.machineAccounts
        inFlightActions.formUnion(ids)
        let task = batch.start(action,
            read: { try await PullRequestActionCheck.fetch($0, viewer: $1, action: action, machineAccounts: machineAccounts) },
            write: { try await GitHubActionRunner.submit($0, action: action) },
            isAllowed: { [self] pr in
                revision == configurationRevision
                    && filtered(allKnown).excluding(ignoreList.ids).contains { $0.id == pr.id }
            },
            didComplete: { [self] pr in
                if revision == configurationRevision { applyCompletedAction(action.action, on: pr) }
                onChange?()
            },
            didFinish: { [self] in
                inFlightActions.subtract(ids)
                reconcileBatch()
                onChange?()
                refresh(force: true)
            }
        )
        if task == nil { inFlightActions.subtract(ids) }
        onChange?()
    }

    func toggleAutopilot() {
        guard !batch.isRunning, !autopilot.isActive else { return }
        if autopilot.isPresented {
            autopilot.close()
        } else if let viewerLogin {
            batch.exit()
            autopilot.present(batchCandidates, viewer: viewerLogin)
        }
    }

    func setAutopilotEnabled(_ enabled: Bool) {
        guard enabled else { autopilot.stop(); return }
        guard !batch.isRunning, let viewerLogin else { return }
        batch.exit()
        let revision = configurationRevision
        let machineAccounts = configuration.machineAccounts
        autopilot.enable(batchCandidates, viewer: viewerLogin, operations: .init(
            read: { candidate, viewer in
                try await PullRequestActionCheck.fetch(candidate.pullRequest, viewer: viewer,
                    action: candidate.action, machineAccounts: machineAccounts)
            },
            write: { try await GitHubActionRunner.submit($0.pullRequest, action: $0.action) },
            reserve: { [self] candidate in inFlightActions.insert(candidate.id).inserted },
            isAllowed: { [self] candidate in
                revision == configurationRevision && batchCandidates.contains { $0.fingerprint == candidate.fingerprint }
            },
            finished: { [self] candidate, completed in
                inFlightActions.remove(candidate.id)
                if revision == configurationRevision {
                    if completed { applyCompletedAction(candidate.action.action, on: candidate.pullRequest) }
                    reconcileBatch()
                    refresh(force: true)
                }
                onChange?()
            }
        ))
    }

    /// El mismo efecto visible para acciones manuales, lotes y Autopilot.
    func applyCompletedAction(_ action: PullRequestAction, on pr: PullRequest) {
        let previousRevision = actionEffects.revision
        actionEffects.record(action, on: pr)
        pullRequests = actionEffects.applying(to: pullRequests, readRevision: previousRevision)
        dependabotPullRequests = actionEffects.applying(to: dependabotPullRequests, readRevision: previousRevision)
        teamDependabotPullRequests = actionEffects.applying(to: teamDependabotPullRequests, readRevision: previousRevision)
        requestedMergeCandidates = actionEffects.applying(to: requestedMergeCandidates, readRevision: previousRevision)
        fixCandidates = actionEffects.applying(to: fixCandidates, readRevision: previousRevision)
        replyCandidates = actionEffects.applying(to: replyCandidates, readRevision: previousRevision)
        waitingReplyCandidates = actionEffects.applying(to: waitingReplyCandidates, readRevision: previousRevision)
        behindCounts = actionEffects.applying(to: behindCounts, readRevision: previousRevision)
    }

    var readyToMerge: [PullRequest] {
        repositoryFilter.prioritizingFavorites(
            in: filtered(mergeCandidates).excluding(ignoreList.ids).readyToMerge
        )
    }

    var needingCIFix: [PullRequest] {
        repositoryFilter.prioritizingFavorites(
            in: filtered(fixCandidates).excluding(ignoreList.ids).needingCIFix
        )
    }

    var needingReply: [PullRequest] {
        repositoryFilter.prioritizingFavorites(
            in: filtered(replyCandidates).excluding(ignoreList.ids)
        )
    }

    var waitingForReply: [PullRequest] {
        repositoryFilter.prioritizingFavorites(
            in: filtered(waitingReplyCandidates).excluding(ignoreList.ids)
        )
    }

    /// Lo que va en el badge: todo lo que espera una acción tuya.
    ///
    /// Suma review, merge, CI por corregir y respuestas pendientes. Deduplica por id porque un check
    /// opcional fallido puede aparecer tanto para fixear como para mergear.
    var actionableCount: Int {
        Set(awaitingYourReview.map(\.id))
            .union(readyToMerge.map(\.id))
            .union(needingCIFix.map(\.id))
            .union(needingReply.map(\.id))
            .count
    }

    /// Desglose para el tooltip: con el badge sumando dos cosas, el número solo
    /// no dice de qué se compone.
    var actionableSummary: String {
        let review = awaitingYourReview.count
        let merge = readyToMerge.count
        let fix = needingCIFix.count
        let reply = needingReply.count
        let parts = [
            review > 0 ? L10n.text(.summaryReview, String(review)) : nil,
            merge > 0 ? L10n.text(.summaryMerge, String(merge)) : nil,
            fix > 0 ? L10n.text(.summaryFix, String(fix)) : nil,
            reply > 0 ? L10n.text(.summaryReply, String(reply)) : nil
        ].compactMap(\.self)
        return parts.isEmpty ? L10n.text(.commonNothingPending) : parts.joined(separator: " · ")
    }

    /// Ignorados que siguen abiertos y en tu cola. Los que se cerraron no
    /// aparecen porque la query ya no los trae.
    var ignored: [PullRequest] {
        repositoryFilter.prioritizingFavorites(
            in: filtered(allKnown).only(ignoreList.ids)
                .sorted { $0.updatedAt > $1.updatedAt }
        )
    }

    /// Mismo orden que el panel; permite localizar el PR sin cambiar filtros.
    func visibleSectionID(for id: String) -> String? {
        let sections: [(String, [PullRequest])] = [
            ("readyToMerge", readyToMerge), ("needingCIFix", needingCIFix),
            ("needingReply", needingReply), ("waitingForReply", waitingForReply)
        ] + reviewSections.map { ($0.bucket == .needsReview ? "needsReview" : "approvedAlready", $0.items) }
            + [("automation", automation), ("ignored", ignored)]
        return sections.first { $0.1.contains { $0.id == id } }?.0
    }

    // MARK: - Acciones

    func setAutomationFilter(_ filter: AutomationFilter) {
        guard automationFilter != filter else { return }
        automationFilter = filter
        automationFilter.persist()
        reconcileBatch()
        onChange?()
    }

    func clearFilters() {
        automationFilter = .all
        automationFilter.persist()
        clearRepositoryFilter()
    }

    func toggleRepositoryFavorite(_ repository: String) {
        repositoryFilter.toggleFavorite(repository)
        repositoryFilterDidChange()
    }

    func toggleRepositorySolo(_ repository: String) {
        repositoryFilter.toggleSolo(repository)
        repositoryFilterDidChange()
    }

    func toggleRepositoryMute(_ repository: String) {
        repositoryFilter.toggleMute(repository)
        repositoryFilterDidChange()
    }

    func clearRepositoryFilter() {
        repositoryFilter.clearSelection()
        repositoryFilterDidChange()
    }

    private func repositoryFilterDidChange() {
        repositoryFilter.persist()
        reconcileBatch()
        onChange?()
    }

    func perform(_ action: PullRequestAction, onID pullRequestID: PullRequest.ID) {
        // Los callbacks y las confirmaciones pueden sobrevivir a un refresh.
        // Resolver por ID evita escribir usando el objeto que capturó la fila.
        guard let pullRequest = currentPullRequest(id: pullRequestID) else { return }
        if action.writesToGitHub {
            guard pullRequest.availableWriteActions(behindBy: behindCount(for: pullRequest))
                .contains(action) else { return }
        }
        switch action {
        case .open:
            let opened = NSWorkspace.shared.open(pullRequest.url)
            activity.record(action, on: pullRequest, status: opened ? .succeeded
                : .failed(LocalizedMessage(L10n.text(.activityOpenFailed))))
        case .ignore:
            ignoreList.ignore(pullRequest)
            activity.record(action, on: pullRequest)
        case .restore:
            ignoreList.restore(pullRequest)
            activity.record(action, on: pullRequest)
        case .dependabotRebase:
            guard pullRequest.canRequestDependabotRebase(
                behindBy: behindCount(for: pullRequest)
            ) else {
                activity.record(action, on: pullRequest,
                    status: .failed(LocalizedMessage(L10n.text(.errorDependabotRebase, pullRequest.shortRepository))))
                break
            }
            write(.dependabotRebase(
                repository: pullRequest.repository,
                number: pullRequest.number
            ), on: pullRequest)
        case .approve:
            write(.approve(
                repository: pullRequest.repository,
                number: pullRequest.number
            ), on: pullRequest)
        case .rebase:
            guard pullRequest.canRebase(behindBy: behindCount(for: pullRequest)) else { return }
            write(.rebase(
                repository: pullRequest.repository,
                number: pullRequest.number
            ), on: pullRequest)
        case .merge:
            // El método lo define el repo. Si no lo sabemos no mergeamos: la
            // acción ni se ofrece, así que llegar acá sin método sería un bug.
            guard let method = pullRequest.defaultMergeMethod else {
                activity.record(action, on: pullRequest,
                    status: .failed(LocalizedMessage(L10n.text(.errorMergeMethod, pullRequest.shortRepository))))
                break
            }
            write(.merge(
                repository: pullRequest.repository,
                number: pullRequest.number,
                method: method
            ), on: pullRequest)
        }
        // Ignorar y restaurar mueven el contador del badge.
        reconcileBatch()
        onChange?()
        if action == .open {
            refresh(force: true)
        }
    }

    func openProject(_ pr: PullRequest, folder: URL) async {
        guard !projectOpener.isOpening else { return }
        let id = activity.record(title: LocalizedMessage(L10n.text(.editorOpen)),
            target: "\(pr.repository) #\(pr.number)", detail: pr.title, url: pr.url,
            symbol: "chevron.left.forwardslash.chevron.right", status: .running)
        await projectOpener.open(.init(pullRequest: pr, folder: folder)) { try await self.editor.open($0) }
        if let warning = projectOpener.warning {
            activity.update(id, status: .skipped(LocalizedMessage(warning.text)))
        } else if let error = projectOpener.error {
            activity.update(id, status: .failed(LocalizedMessage(error.localizedDescription)))
        } else {
            activity.update(id, status: .succeeded)
        }
    }

    func openProjectWithoutBranch() async {
        guard !projectOpener.isOpening, let warning = projectOpener.warning else { return }
        let request = warning.request
        let id = activity.record(title: LocalizedMessage(L10n.text(.editorOpenProject)),
            target: "\(request.repository) #\(request.url.lastPathComponent)", url: request.url,
            symbol: "chevron.left.forwardslash.chevron.right", status: .running)
        await projectOpener.openWithoutBranch { try await self.editor.open($0) }
        if let error = projectOpener.error {
            activity.update(id, status: .failed(LocalizedMessage(error.localizedDescription)))
        } else {
            activity.update(id, status: .succeeded)
        }
    }

    func openAgent(_ pr: PullRequest, folder: URL) async {
        guard !agentCLI.isOpening else { return }
        let title = agentCLI.openTitle
        let id = activity.record(title: LocalizedMessage(title), target: "\(pr.repository) #\(pr.number)",
            detail: pr.title, url: pr.url, symbol: "terminal", status: .running)
        await agentCLI.open(folder, id: pr.id) { [activity] result in
            let status: ActivityLog.Status
            switch result {
            case .success: status = .succeeded
            case .failure(let error): status = .failed(LocalizedMessage(error.localizedDescription))
            }
            // Una terminal personalizada puede fallar después de arrancar.
            // Si se limpió el historial mientras tanto, volvemos a mostrar el error.
            activity.record(id: id, title: LocalizedMessage(title), target: "\(pr.repository) #\(pr.number)",
                detail: pr.title, url: pr.url, symbol: "terminal", status: status)
        }
    }

    func isIgnored(_ pullRequest: PullRequest) -> Bool {
        ignoreList.contains(pullRequest)
    }

    /// `nil` si no se pudo medir. No es `0`.
    func behindCount(for pullRequest: PullRequest) -> Int? {
        behindCounts[pullRequest.id]
    }

    /// Todo lo conocido, sin duplicados: la cola de review y la de merge sí se
    /// solapan (un PR aprobado por vos está en las dos).
    private var allKnown: [PullRequest] {
        // Review es una consulta parcial: no debe tapar los datos de merge,
        // incluidos los estados BLOCKED/UNKNOWN recibidos en el último refresh.
        (mergeCandidates + reviewQueue + fixCandidates + replyCandidates + waitingReplyCandidates).uniquedByID()
    }

    func currentPullRequest(id: PullRequest.ID) -> PullRequest? {
        allKnown.first { $0.id == id }
    }

    func isAvailable(_ pending: PendingPullRequestAction) -> Bool {
        !inFlightActions.contains(pending.pullRequestID)
            && pending.isAvailable(for: currentPullRequest(id: pending.pullRequestID),
                                   behindBy: behindCounts[pending.pullRequestID])
    }

    func isActing(on pullRequest: PullRequest) -> Bool {
        inFlightActions.contains(pullRequest.id)
    }

    /// Valida, guarda y aplica el alcance sin tener que reiniciar la app.
    func updateConfiguration(organizations: Set<String>, machineAccounts: String,
                             teamDependabotEnabled: Bool? = nil, dependabotTeams: Set<String>? = nil) throws {
        let updated = try AppConfiguration(
            organizations: organizations,
            machineAccountsText: machineAccounts,
            teamDependabotEnabled: teamDependabotEnabled ?? configuration.teamDependabotEnabled,
            dependabotTeams: dependabotTeams ?? configuration.dependabotTeams
        )
        guard updated != configuration else { return }

        configuration = updated
        configuration.persist()
        configurationRevision += 1
        actionEffects = PullRequestActionEffects()
        viewerLogin = nil
        inFlight?.cancel()
        inFlight = nil
        hasPendingRefresh = false

        // No dejamos datos del alcance anterior visibles mientras carga el nuevo.
        pullRequests = []
        dependabotPullRequests = []
        requestedMergeCandidates = []
        teamDependabotPullRequests = []
        teamDependabotFailure = nil
        isLoadingTeamDependabot = false
        fixCandidates = []
        replyCandidates = []
        waitingReplyCandidates = []
        behindCounts = [:]
        lastUpdated = nil
        state = .idle
        notificationTracker.resetBaseline()
        reconcileBatch()
        onChange?()
        refresh(force: true)
    }

    private func write(_ operation: GitHubWrite, on pullRequest: PullRequest) {
        // Una escritura por PR a la vez: el doble click no manda dos merges.
        guard inFlightActions.insert(pullRequest.id).inserted else { return }
        reconcileBatch()
        onChange?()

        let activityID = activity.record(operation.action, on: pullRequest, status: .running)
        let revision = configurationRevision
        let viewer = viewerLogin
        Task {
            do {
                if let action = operation.action.batchAction {
                    guard let viewer else { throw GH.Failure.badJSON("Missing viewer") }
                    let result = try await GitHubActionRunner.shared.perform(
                        pullRequest, viewer: viewer, action: action, batch: false,
                        read: { try await PullRequestActionCheck.fetch($0, viewer: $1, action: action) },
                        write: { try await GitHubActionRunner.submit($0, action: action) },
                        isAllowed: { [self] _ in revision == configurationRevision },
                        progress: { [activity] progress in
                            switch progress {
                            case .checking: activity.update(activityID, status: .checking)
                            case .executing: activity.update(activityID, status: .running)
                            case .waiting(let seconds, let attempt):
                                activity.update(activityID, status: .waiting(seconds: seconds, attempt: attempt))
                            }
                        }
                    )
                    if case .skipped(let reason) = result, reason != .alreadyApproved && reason != .alreadyMerged {
                        throw PullRequestActionSkipped(reason: reason)
                    }
                } else {
                    // Las demás escrituras conservan un único intento: un error
                    // de transporte puede llegar después de aplicar la acción.
                    _ = try await GH.run(operation.arguments)
                }

                if revision == configurationRevision {
                    applyCompletedAction(operation.action, on: pullRequest)
                }

                activity.update(activityID, status: .succeeded)
            } catch let error as PullRequestActionSkipped {
                activity.update(activityID, status: .skipped(LocalizedMessage(error.reason.text)))
            } catch {
                activity.update(activityID, status: .failed(LocalizedMessage(error.localizedDescription)))
            }
            inFlightActions.remove(pullRequest.id)
            reconcileBatch()
            onChange?()
            // Consultamos todas las colas al finalizar, incluso si GitHub
            // devolvió un error y no sabemos si alcanzó a aplicar la escritura.
            refresh(force: true)
        }
    }

    // MARK: - Carga

    func refresh(force: Bool = false) {
        if !force, let lastUpdated, Date().timeIntervalSince(lastUpdated) < Self.staleAfter {
            return
        }
        guard inFlight == nil else {
            if force { hasPendingRefresh = true }
            return
        }

        state = .loading
        onChange?()

        let requestedConfiguration = configuration
        let requestedRevision = configurationRevision
        let readRevision = actionEffects.revision
        let requestedTeamDiscovery = forceTeamDiscovery
        forceTeamDiscovery = false
        isLoadingTeamDependabot = !requestedConfiguration.effectiveDependabotTeams.isEmpty

        // Sin `weak self`: el store vive todo lo que vive la app.
        inFlight = Task {
            await Diagnostics.refresh(.github, forced: force) {
                var firstContent = false
                do {
                    try await Diagnostics.measure(.preflight) { try await GH.preflight() }
                    // Una identidad por actualización, sin caché entre cuentas ni ciclos.
                    let viewer = try await Viewer.fetch()
                    guard requestedRevision == configurationRevision, !Task.isCancelled else { return }
                    viewerLogin = viewer.login
                    // Detenemos inmediatamente si la cuenta cambió, incluso si falla una query.
                    autopilot.reconcile(batchCandidates, viewer: viewer.login)

                    let completed = try await GitHubQueueRefresh.load(queries: .live(
                        configuration: requestedConfiguration, viewer: viewer,
                        forceTeamDiscovery: requestedTeamDiscovery
                    )) { update in
                        guard requestedRevision == self.configurationRevision, !Task.isCancelled else { return }
                        self.publish(update, readRevision: readRevision, firstContent: &firstContent)
                    }
                    guard requestedRevision == configurationRevision, !Task.isCancelled else { return }
                    // Publicar es independiente; las notificaciones esperan las
                    // fuentes completas para no tratar un backlog como novedades.
                    if completed.canNotifyMerge {
                        await Diagnostics.measure(.notifications) {
                            await notifier.send(notificationTracker.process(readyToMerge, in: .merge))
                        }
                        guard requestedRevision == configurationRevision, !Task.isCancelled else { return }
                    }
                    if completed.canNotifyReview {
                        await Diagnostics.measure(.notifications) {
                            await notifier.send(notificationTracker.process(awaitingYourReview, in: .review))
                        }
                        guard requestedRevision == configurationRevision, !Task.isCancelled else { return }
                    }
                    // Recién con todas las colas consultadas podemos mostrar un
                    // estado vacío. Medir ramas después no agrega ni quita PRs.
                    lastUpdated = .now
                    state = .loaded
                    Diagnostics.record(.queuesLoaded)
                    onChange?()
                    let counts = await Diagnostics.measure(.behind) { await BehindCount.fetch(for: allKnown) }
                    guard requestedRevision == configurationRevision, !Task.isCancelled else { return }
                    behindCounts = actionEffects.applying(to: counts, readRevision: readRevision)
                    actionEffects.finishRefresh(startedAt: readRevision)
                } catch {
                    guard requestedRevision == configurationRevision else { return }
                    Diagnostics.record(.failed, error: error)
                    state = .failed(LocalizedMessage(error.localizedDescription))
                }
                guard requestedRevision == configurationRevision else { return }
                inFlight = nil
                isLoadingTeamDependabot = false
                onChange?()
                if hasPendingRefresh {
                    hasPendingRefresh = false
                    refresh(force: true)
                }
            }
        }
    }

    private func publish(_ update: GitHubQueueRefresh.Update, readRevision: Int, firstContent: inout Bool) {
        let phase: Diagnostics.Phase
        let count: Int
        switch update {
        case .review(let prs):
            pullRequests = actionEffects.applying(to: prs, readRevision: readRevision)
            phase = .review
            count = prs.count
        case .merge(let prs):
            requestedMergeCandidates = actionEffects.applying(to: prs, readRevision: readRevision)
            phase = .merge
            count = prs.count
        case .own(let prs):
            fixCandidates = actionEffects.applying(to: prs, readRevision: readRevision)
            phase = .own
            count = prs.count
        case .dependabot(let prs):
            dependabotPullRequests = actionEffects.applying(to: prs, readRevision: readRevision)
            phase = .dependabot
            count = prs.count
        case .team(let result):
            isLoadingTeamDependabot = false
            teamDependabotFailure = result.error.map { LocalizedMessage(L10n.text(.errorTeamDiscovery, $0)) }
            guard let prs = result.pullRequests else { onChange?(); return }
            teamDependabotPullRequests = actionEffects.applying(to: prs, readRevision: readRevision)
            phase = .teamDependabot
            count = prs.count
        case .replies(let replies):
            replyCandidates = actionEffects.applying(to: replies.needingReply, readRevision: readRevision)
            waitingReplyCandidates = actionEffects.applying(to: replies.waitingForReply, readRevision: readRevision)
            phase = .replies
            count = replies.needingReply.count + replies.waitingForReply.count
        }
        recordPublication(phase, count: count, firstContent: &firstContent)
        reconcileBatch()
        onChange?()
    }

    private func recordPublication(_ phase: Diagnostics.Phase, count: Int, firstContent: inout Bool) {
        Diagnostics.record(.published, phase: phase, metrics: [.items: count])
        if !firstContent,
           !reviewSections.isEmpty || !readyToMerge.isEmpty || !needingCIFix.isEmpty
            || !needingReply.isEmpty || !waitingForReply.isEmpty || !automation.isEmpty || !ignored.isEmpty {
            firstContent = true
            Diagnostics.record(.firstContent)
        }
    }

}

#if DEBUG
extension ReviewQueueStore {
    /// Datos en memoria para previews del panel, sin consultas ni escrituras remotas.
    static func preview(reviews: [PullRequest], merges: [PullRequest],
                        batch: PullRequestBatch = PullRequestBatch(), viewer: String = "me") -> ReviewQueueStore {
        let store = ReviewQueueStore(batch: batch)
        store.viewerLogin = viewer
        store.repositoryFilter = RepositoryFilter()
        store.automationFilter = .all
        store.configuration = .empty
        store.pullRequests = reviews
        store.requestedMergeCandidates = merges
        store.state = .loaded
        return store
    }
}
#endif
