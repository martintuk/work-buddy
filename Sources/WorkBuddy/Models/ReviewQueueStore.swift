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

    /// Cada 5 minutos: a 4s por consulta y con 5000 puntos/hora de presupuesto
    /// GraphQL, 12 refreshes por hora no mueven la aguja.
    static let autoRefreshInterval: TimeInterval = 300

    private(set) var state: State = .idle
    private(set) var configuration = AppConfiguration.load()
    private(set) var repositoryFilter = RepositoryFilter.load()
    private(set) var pullRequests: [PullRequest] = []
    /// PRs de dependabot. Lista aparte porque vienen de otra query y porque
    /// **nunca** notifican ni cuentan para el badge: son 50 contra 7 de
    /// personas, así que mezclarlos haría que el número dejara de significar
    /// algo. Aparecen sólo en la sección colapsada de automatización.
    private(set) var dependabotPullRequests: [PullRequest] = []
    /// Candidatos a merge. Vienen de otra query porque pedirle a GitHub que
    /// calcule la mergeabilidad de toda la cola de review es caro.
    private(set) var mergeCandidates: [PullRequest] = []
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
    private let ignoreList = IgnoreList()
    private var inFlight: Task<Void, Never>?
    private var autoRefresh: Task<Void, Never>?
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
        repositoryFilter.prioritizingFavorites(in: visible.automation)
    }

    var awaitingYourReview: [PullRequest] { visible.awaitingYourReview }

    var readyToMerge: [PullRequest] {
        repositoryFilter.prioritizingFavorites(
            in: repositoryFilter.apply(to: mergeCandidates).excluding(ignoreList.ids).readyToMerge
        )
    }

    /// Lo que va en el badge: todo lo que espera una acción tuya.
    ///
    /// Suma dos fuentes —lo que tenés que revisar y lo que podés mergear de un
    /// click— y las deduplica por id, porque salen de queries distintas y nada
    /// garantiza que no se solapen.
    var actionableCount: Int {
        Set(awaitingYourReview.map(\.id))
            .union(readyToMerge.map(\.id))
            .count
    }

    /// Desglose para el tooltip: con el badge sumando dos cosas, el número solo
    /// no dice de qué se compone.
    var actionableSummary: String {
        let review = awaitingYourReview.count
        let merge = readyToMerge.count
        let parts = [
            review > 0 ? "\(review) para revisar" : nil,
            merge > 0 ? "\(merge) para mergear" : nil
        ].compactMap(\.self)
        return parts.isEmpty ? "Nada pendiente" : parts.joined(separator: " · ")
    }

    /// Ignorados que siguen abiertos y en tu cola. Los que se cerraron no
    /// aparecen porque la query ya no los trae.
    var ignored: [PullRequest] {
        repositoryFilter.prioritizingFavorites(
            in: repositoryFilter.apply(to: reviewQueue).only(ignoreList.ids)
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
        return (reviewQueue + mergeCandidates).filter { seen.insert($0.id).inserted }
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

        // No dejamos datos del alcance anterior visibles mientras carga el nuevo.
        pullRequests = []
        dependabotPullRequests = []
        mergeCandidates = []
        behindCounts = [:]
        lastUpdated = nil
        state = .idle
        notifier.resetBaseline()
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

                if case .rebase = operation {
                    // La comparación anterior ya no describe la rama actual.
                    // No ofrecemos otro rebase hasta volver a medir el atraso.
                    behindCounts.removeValue(forKey: pullRequest.id)
                }

                outcome = Outcome(
                    text: "\(operation.pastTense): \(pullRequest.shortRepository) "
                        + "#\(pullRequest.number)",
                    isError: false
                )
                // Aprobar te saca de los review requests y mergear cierra el PR:
                // en los dos casos la fila desaparece del panel, así que el aviso
                // es la única señal de que la acción funcionó.
                refresh(force: true)
            } catch {
                outcome = Outcome(
                    text: (error as? LocalizedError)?.errorDescription
                        ?? error.localizedDescription,
                    isError: true
                )
            }
            inFlightActions.remove(pullRequest.id)
            onChange?()
        }
    }

    // MARK: - Carga

    func refresh(force: Bool = false) {
        if !force, let lastUpdated, Date().timeIntervalSince(lastUpdated) < Self.staleAfter {
            return
        }
        guard inFlight == nil else { return }

        state = .loading
        onChange?()

        let requestedConfiguration = configuration
        let requestedRevision = configurationRevision

        // Sin `weak self`: el store vive todo lo que vive la app.
        inFlight = Task {
            do {
                try await GH.preflight()

                // Las dos queries son independientes: van en paralelo.
                async let reviewQueue = ReviewQueue.fetch(configuration: requestedConfiguration)
                async let mergeQueue = MergeQueue.fetch(configuration: requestedConfiguration)

                let fetched = try await reviewQueue
                guard requestedRevision == configurationRevision else { return }
                pullRequests = fetched

                // Los candidatos a merge son secundarios: si esa query falla,
                // mostramos la cola de review igual en vez de dejar el panel en
                // estado de error.
                mergeCandidates = (try? await mergeQueue) ?? mergeCandidates
                guard requestedRevision == configurationRevision else { return }

                // Sólo lo de personas notifica: `fetched` no incluye dependabot,
                // que llega en la segunda fase. Un PR ignorado tampoco notifica;
                // si más adelante lo restaurás, vuelve a contar como nuevo y
                // avisa una vez.
                await notifier.process(repositoryFilter.apply(to: fetched).excluding(ignoreList.ids))
                guard requestedRevision == configurationRevision else { return }

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
        }
    }

    /// Arranca el ciclo de refresh en background y consulta el permiso de notificaciones.
    func start() {
        Task { await notifier.refreshAuthorization() }
        refresh()

        autoRefresh?.cancel()
        autoRefresh = Task {
            while !Task.isCancelled {
                // Durante el sleep del sistema el reloj no corre: al despertar
                // se completa lo que faltaba y sigue. No hace falta manejarlo.
                try? await Task.sleep(for: .seconds(Self.autoRefreshInterval))
                guard !Task.isCancelled else { return }
                refresh(force: true)
            }
        }
    }
}
