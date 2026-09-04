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
        case failed(String)
    }

    /// Pasado este tiempo, abrir el panel dispara un refresh.
    private static let staleAfter: TimeInterval = 120

    private(set) var state: State = .idle
    private(set) var configuration = AppConfiguration.load()
    private(set) var repositoryFilter = RepositoryFilter.load()
    private(set) var pullRequests: [PullRequest] = []
    /// PRs de dependabot en la cola de review, mostrados en automatización.
    /// Los que están para mergear llegan por `mergeCandidates`.
    private(set) var dependabotPullRequests: [PullRequest] = []
    /// Candidatos a merge. Vienen de otra query porque pedirle a GitHub que
    /// calcule la mergeabilidad de toda la cola de review es caro.
    private(set) var mergeCandidates: [PullRequest] = []
    /// PRs propios; se consultan aparte aunque no esperen review ni puedan mergearse.
    private(set) var fixCandidates: [PullRequest] = []
    private(set) var replyCandidates: [PullRequest] = []
    private(set) var lastUpdated: Date?

    /// Resultado de la última acción que escribió en GitHub.
    struct Outcome {
        let text: String
        let isError: Bool
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

    /// La cola de review completa: personas y dependabot. No hace falta
    /// deduplicar porque los filtros de las dos queries son complementarios
    /// exactos (`-author:app/dependabot` contra `author:app/dependabot`).
    private var reviewQueue: [PullRequest] { pullRequests + dependabotPullRequests }

    /// Todo lo visible sale de acá: los ignorados se filtran una sola vez, así
    /// no hay forma de que el badge cuente algo que el panel no muestra.
    private var visible: [PullRequest] {
        repositoryFilter.apply(to: reviewQueue).excluding(ignoreList.ids)
    }

    var repositories: [RepositoryFilter.Repository] {
        repositoryFilter.repositories(in: allKnown)
    }

    var hasRepositoryFilteredResults: Bool {
        allKnown.contains { !repositoryFilter.includes($0.repository) }
    }

    var humanSections: [(bucket: ReviewBucket, items: [PullRequest])] {
        visible.humanSections.map { section in
            (section.bucket, repositoryFilter.prioritizingFavorites(in: section.items))
        }
    }

    var automation: [PullRequest] {
        repositoryFilter.prioritizingFavorites(in: visible.automation).prioritizingSuccessfulCI
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
            review > 0 ? "\(review) para revisar" : nil,
            merge > 0 ? "\(merge) para mergear" : nil,
            fix > 0 ? "\(fix) para fixear" : nil,
            reply > 0 ? "\(reply) para responder" : nil
        ].compactMap(\.self)
        return parts.isEmpty ? "Nada pendiente" : parts.joined(separator: " · ")
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

    func perform(_ action: PullRequestAction, on pullRequest: PullRequest) {
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
                    text: "Dependabot no puede rebasear \(pullRequest.shortRepository)",
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
                    text: "No sé qué método de merge usa \(pullRequest.shortRepository)",
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
        if !action.writesToGitHub {
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
        var seen: Set<String> = []
        return (reviewQueue + mergeCandidates + fixCandidates + replyCandidates).filter { seen.insert($0.id).inserted }
    }

    func isActing(on pullRequest: PullRequest) -> Bool {
        inFlightActions.contains(pullRequest.id)
    }

    func dismissOutcome() {
        outcome = nil
    }

    /// Valida, guarda y aplica el alcance sin tener que reiniciar la app.
    func updateConfiguration(organizations: Set<String>, machineAccounts: String) throws {
        let updated = try AppConfiguration(
            organizations: organizations,
            machineAccountsText: machineAccounts
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
        mergeCandidates = []
        fixCandidates = []
        replyCandidates = []
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

        // Sin `weak self`: el store vive todo lo que vive la app.
        inFlight = Task {
            do {
                try await GH.preflight()

                // Las consultas de review, merge y CI propia son independientes.
                async let reviewQueue = ReviewQueue.fetch(configuration: requestedConfiguration)
                async let mergeQueue = MergeQueue.fetch(configuration: requestedConfiguration)
                async let fixQueue = FixQueue.fetch(configuration: requestedConfiguration)

                let fetched = try await reviewQueue
                guard requestedRevision == configurationRevision else { return }
                pullRequests = fetched

                // Los candidatos a merge son secundarios: si esa query falla,
                // mostramos la cola de review igual en vez de dejar el panel en
                // estado de error.
                let fetchedMergeCandidates = try? await mergeQueue
                guard requestedRevision == configurationRevision else { return }
                if let fetchedMergeCandidates {
                    mergeCandidates = fetchedMergeCandidates
                }

                // Una falla de esta consulta conserva el último resultado conocido,
                // igual que la cola de merge, sin descartar las otras secciones.
                let fetchedFixCandidates = try? await fixQueue
                guard requestedRevision == configurationRevision else { return }
                if let fetchedFixCandidates {
                    fixCandidates = fetchedFixCandidates
                }

                var notifications = notificationTracker.process(awaitingYourReview, in: .review)
                // No sembrar ni reemplazar la base de merge si su consulta falló.
                if fetchedMergeCandidates != nil {
                    notifications += notificationTracker.process(readyToMerge, in: .merge)
                }
                await notifier.send(notifications)
                guard requestedRevision == configurationRevision else { return }

                // La lista propia ya está disponible. Una falla de hilos conserva
                // la última clasificación sin impedir que se actualice la CI.
                onChange?()
                if let fetchedFixCandidates {
                    let replies = try? await ReplyQueue.fetch(for: fetchedFixCandidates)
                    guard requestedRevision == configurationRevision else { return }
                    if let replies { replyCandidates = replies }
                }

                // Segunda fase: lo caro, después de que el panel se dibujó.
                // Dependabot son 50 PRs (~9s) y comparar ramas ~4s por cada 20.
                // Va en este orden porque los "N atrás" de dependabot son el
                // dato que decide si hace falta un rebase, así que necesitamos
                // la lista antes de medir.
                onChange?()
                dependabotPullRequests =
                    (try? await DependabotQueue.fetch(configuration: requestedConfiguration))
                    ?? dependabotPullRequests
                guard requestedRevision == configurationRevision else { return }
                // Recién con todas las colas consultadas podemos mostrar un
                // estado vacío. Medir ramas después no agrega ni quita PRs.
                lastUpdated = .now
                state = .loaded
                onChange?()
                behindCounts = await BehindCount.fetch(for: allKnown)
            } catch {
                guard requestedRevision == configurationRevision else { return }
                state = .failed((error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription)
            }
            guard requestedRevision == configurationRevision else { return }
            inFlight = nil
            onChange?()
            if hasPendingRefresh {
                hasPendingRefresh = false
                refresh(force: true)
            }
        }
    }

}
