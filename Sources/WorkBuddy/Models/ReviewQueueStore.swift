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
    let localRepositories = LocalRepositoryStore()
    let editor = EditorStore()
    let agentCLI = AgentCLIStore()
    let projectOpener = ProjectOpener()
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

    /// Resultado de la última acción que escribió en GitHub.
    struct Outcome {
        private let message: LocalizedMessage
        let isError: Bool
        var text: String { message.text }

        init(text: @autoclosure @escaping () -> String, isError: Bool) {
            message = LocalizedMessage(text())
            self.isError = isError
        }
    }

    /// `behindBy` por id de PR. Un id **ausente** es "no medido", que no es lo
    /// mismo que `0` = "al día": si los confundimos, el rebase pasa a ser una
    /// adivinanza.
    private(set) var behindCounts: [String: Int] = [:]

    private(set) var outcome: Outcome?
    /// Ids de PRs con una escritura en curso.
    private(set) var inFlightActions: Set<String> = []

    /// La barra de menú es AppKit y no participa de la observación de SwiftUI,
    /// así que le avisamos por acá cuándo repintar el badge.
    var onChange: (() -> Void)?

    let notifier = Notifier()
    private let notificationTracker = PullRequestNotificationTracker()
    private let ignoreList = IgnoreList()
    private var inFlight: Task<Void, Never>?
    /// Una acción durante una consulta necesita otra lectura al terminar.
    private var hasPendingRefresh = false
    /// Invalida resultados de una consulta que empezó con otra configuración.
    private var configurationRevision = 0

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
        repositoryFilter.apply(to: reviewQueue).excluding(ignoreList.ids)
            .excludingMergeableAutomation(in: mergeCandidates)
    }

    var repositories: [RepositoryFilter.Repository] {
        repositoryFilter.repositories(in: allKnown, including: localRepositories.repositories)
    }

    var hasRepositoryFilteredResults: Bool {
        allKnown.contains { !repositoryFilter.includes($0.repository) }
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

    var readyToMerge: [PullRequest] {
        repositoryFilter.prioritizingFavorites(
            in: repositoryFilter.apply(to: mergeCandidates).excluding(ignoreList.ids).readyToMerge
        )
    }

    var needingCIFix: [PullRequest] {
        repositoryFilter.prioritizingFavorites(
            in: repositoryFilter.apply(to: fixCandidates).excluding(ignoreList.ids).needingCIFix
        )
    }

    var needingReply: [PullRequest] {
        repositoryFilter.prioritizingFavorites(
            in: repositoryFilter.apply(to: replyCandidates).excluding(ignoreList.ids)
        )
    }

    var waitingForReply: [PullRequest] {
        repositoryFilter.prioritizingFavorites(
            in: repositoryFilter.apply(to: waitingReplyCandidates).excluding(ignoreList.ids)
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
            in: repositoryFilter.apply(to: allKnown).only(ignoreList.ids)
                .sorted { $0.updatedAt > $1.updatedAt }
        )
    }

    // MARK: - Acciones

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
            NSWorkspace.shared.open(pullRequest.url)
        case .ignore:
            ignoreList.ignore(pullRequest)
        case .restore:
            ignoreList.restore(pullRequest)
        case .dependabotRebase:
            guard pullRequest.canRequestDependabotRebase(
                behindBy: behindCount(for: pullRequest)
            ) else {
                outcome = Outcome(
                    text: L10n.text(.errorDependabotRebase, pullRequest.shortRepository),
                    isError: true
                )
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
                outcome = Outcome(
                    text: L10n.text(.errorMergeMethod, pullRequest.shortRepository),
                    isError: true
                )
                break
            }
            write(.merge(
                repository: pullRequest.repository,
                number: pullRequest.number,
                method: method
            ), on: pullRequest)
        }
        // Ignorar y restaurar mueven el contador del badge.
        onChange?()
        if action == .open {
            refresh(force: true)
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

    func dismissOutcome() {
        outcome = nil
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
        onChange?()
        refresh(force: true)
    }

    private func write(_ operation: GitHubWrite, on pullRequest: PullRequest) {
        // Una escritura por PR a la vez: el doble click no manda dos merges.
        guard inFlightActions.insert(pullRequest.id).inserted else { return }
        outcome = nil
        onChange?()

        Task {
            do {
                // `GH.run` y no `runRetrying`: una escritura que falló a mitad de
                // camino no es segura de repetir a ciegas. Un 502 después de que
                // el merge entró reintentaría sobre un PR ya cerrado.
                _ = try await GH.run(operation.arguments)

                switch operation {
                case .merge:
                    // Sacamos el PR del snapshot local apenas GitHub confirma.
                    // Sin exclusión persistente: cada consulta puede traerlo de nuevo.
                    pullRequests.removeAll { $0.id == pullRequest.id }
                    dependabotPullRequests.removeAll { $0.id == pullRequest.id }
                    requestedMergeCandidates.removeAll { $0.id == pullRequest.id }
                    teamDependabotPullRequests.removeAll { $0.id == pullRequest.id }
                    fixCandidates.removeAll { $0.id == pullRequest.id }
                    replyCandidates.removeAll { $0.id == pullRequest.id }
                    waitingReplyCandidates.removeAll { $0.id == pullRequest.id }
                    behindCounts.removeValue(forKey: pullRequest.id)
                case .rebase, .dependabotRebase:
                    // La comparación anterior ya no describe la rama actual.
                    // No ofrecemos otro rebase hasta volver a medir el atraso.
                    behindCounts.removeValue(forKey: pullRequest.id)
                default:
                    break
                }

                outcome = Outcome(
                    text: "\(operation.pastTense): \(pullRequest.shortRepository) "
                        + "#\(pullRequest.number)",
                    isError: false
                )
            } catch {
                outcome = Outcome(
                    text: (error as? LocalizedError)?.errorDescription
                        ?? error.localizedDescription,
                    isError: true
                )
            }
            inFlightActions.remove(pullRequest.id)
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

                    let completed = try await GitHubQueueRefresh.load(queries: .live(
                        configuration: requestedConfiguration, viewer: viewer,
                        forceTeamDiscovery: requestedTeamDiscovery
                    )) { update in
                        guard requestedRevision == self.configurationRevision, !Task.isCancelled else { return }
                        self.publish(update, firstContent: &firstContent)
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
                    behindCounts = counts
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

    private func publish(_ update: GitHubQueueRefresh.Update, firstContent: inout Bool) {
        let phase: Diagnostics.Phase
        let count: Int
        switch update {
        case .review(let prs):
            pullRequests = prs
            phase = .review
            count = prs.count
        case .merge(let prs):
            requestedMergeCandidates = prs
            phase = .merge
            count = prs.count
        case .own(let prs):
            fixCandidates = prs
            phase = .own
            count = prs.count
        case .dependabot(let prs):
            dependabotPullRequests = prs
            phase = .dependabot
            count = prs.count
        case .team(let result):
            isLoadingTeamDependabot = false
            teamDependabotFailure = result.error.map { LocalizedMessage(L10n.text(.errorTeamDiscovery, $0)) }
            guard let prs = result.pullRequests else { onChange?(); return }
            teamDependabotPullRequests = prs
            phase = .teamDependabot
            count = prs.count
        case .replies(let replies):
            replyCandidates = replies.needingReply
            waitingReplyCandidates = replies.waitingForReply
            phase = .replies
            count = replies.needingReply.count + replies.waitingForReply.count
        }
        recordPublication(phase, count: count, firstContent: &firstContent)
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
