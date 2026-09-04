import Foundation
import Testing

@testable import WorkBuddy

/// La clasificación en buckets ya se equivocó dos veces contra datos reales:
/// una usando el estado de CI como filtro, otra contando approvals a mano.
/// Las dos quedaron acá como casos fijos.
@Suite("Clasificación de PRs")
struct ReviewBucketTests {
    // MARK: - Regresiones encontradas contra la API real

    @Test("Approvals que GitHub no acepta no marcan el PR como cubierto")
    func approvalsNoAlcanzanSiGitHubPideReview() {
        // Un caso real tenía 3 approvals y reviewDecision REVIEW_REQUIRED,
        // porque faltaba un CODEOWNER. Contar approvals a mano lo archivaba como
        // cubierto cuando todavía necesitaba review.
        let pullRequest = makePullRequest(
            requestedFromMe: false,
            approvals: 3,
            reviewDecision: .reviewRequired
        )
        #expect(pullRequest.bucket() == .needsReview)
    }

    @Test("CI en rojo nunca esconde un PR que espera tu review")
    func ciRojaNoCambiaElBucket() {
        // `statusCheckRollup` incluye checks opcionales: usarlo como filtro
        // escondía 40 de 63 PRs, muchos de los cuales sí necesitaban review.
        let pullRequest = makePullRequest(requestedFromMe: true, checks: .failure)
        #expect(pullRequest.bucket() == .needsReview)
    }

    // MARK: - Prioridad entre buckets

    @Test("Un PR aprobado es opcional aunque te lo sigan pidiendo")
    func aprobadoGanaSobrePedidoPersonal() {
        let pullRequest = makePullRequest(
            requestedFromMe: true,
            reviewedByMe: false,
            approvals: 2,
            reviewDecision: .approved
        )
        #expect(pullRequest.bucket() == .approvedAlready)
    }

    @Test("La antigüedad no cambia una review pendiente ni un PR aprobado",
          arguments: [1, 29, 30, 31, 40, 365])
    func antiguedadNoCambiaLaAccion(days: Int) {
        let updatedAt = Date.now.addingTimeInterval(-Double(days) * 24 * 60 * 60)
        let pendiente = makePullRequest(requestedFromMe: true, updatedAt: updatedAt)
        let aprobado = makePullRequest(reviewDecision: .approved, updatedAt: updatedAt)
        #expect(pendiente.bucket() == .needsReview)
        #expect(aprobado.bucket() == .approvedAlready)
        #expect([pendiente, aprobado].awaitingYourReview.map(\.id) == [pendiente.id])
    }

    @Test("Pedidos personales y de equipo usan las mismas reglas",
          arguments: [false, true], [false, true])
    func pedidosEquivalentes(requestedFromMe: Bool, reviewedByMe: Bool) {
        for decision: ReviewDecision? in [nil, .reviewRequired, .changesRequested, .approved] {
            let pr = makePullRequest(
                requestedFromMe: requestedFromMe,
                reviewedByMe: reviewedByMe,
                approvals: 3,
                reviewDecision: decision
            )
            #expect(pr.bucket() == (decision == .approved ? .approvedAlready : .needsReview))
            #expect([pr].awaitingYourReview.isEmpty == (decision == .approved))
        }
    }

    @Test("Mi aprobación excluye ambas categorías aunque el pedido siga activo",
          arguments: [false, true], [false, true])
    func aprobadoPorMiNoPideReview(requestedFromMe: Bool, globallyApproved: Bool) {
        let pr = makePullRequest(
            requestedFromMe: requestedFromMe,
            reviewedByMe: true,
            approvedByMe: true,
            reviewDecision: globallyApproved ? .approved : .reviewRequired
        )
        #expect(pr.bucket() == nil)
        #expect([pr].reviewSections.isEmpty)
        #expect([pr].awaitingYourReview.isEmpty)
    }

    @Test("Los approvals ajenos no equivalen a una aprobación personal")
    func aprobadoPorOtrosSigueVisible() {
        let pr = makePullRequest(approvals: 2, reviewDecision: .approved)
        #expect([pr].reviewSections.map(\.bucket) == [.approvedAlready])
        #expect([pr].reviewSections.first?.items.map(\.id) == [pr.id])
    }

    // MARK: - Casos base

    @Test("Pedido a vos y sin revisar todavía: para revisar")
    func pedidoAMiSinRevisar() {
        #expect(makePullRequest(requestedFromMe: true).bucket() == .needsReview)
    }

    @Test("Haberlo revisado antes no crea otra categoría")
    func revisadoYVueltoAPedir() {
        let pullRequest = makePullRequest(requestedFromMe: true, reviewedByMe: true)
        #expect(pullRequest.bucket() == .needsReview)
    }

    @Test("Pedido sólo al equipo: para revisar")
    func pedidoAlEquipo() {
        #expect(makePullRequest(requestedFromMe: false).bucket() == .needsReview)
    }
}

@Suite("Clasificación de autores")
struct AuthorTests {
    @Test("GitHub tipa los bots explícitamente")
    func typenameBot() {
        #expect(Author(login: "dependabot", typename: "Bot").isBot)
    }

    @Test("Las cuentas de máquina vienen tipadas como User")
    func cuentaDeMaquina() {
        #expect(Author(
            login: "ci-service-user",
            typename: "User",
            machineAccounts: ["ci-service-user"]
        ).isBot)
    }

    @Test("Una persona no es bot")
    func persona() {
        #expect(!Author(login: "alice", typename: "User").isBot)
    }

    @Test("Sin typename se cae a la lista de cuentas de máquina")
    func typenameAusente() {
        #expect(!Author(login: "alice", typename: nil).isBot)
        #expect(Author(
            login: "ci-service-user",
            typename: nil,
            machineAccounts: ["ci-service-user"]
        ).isBot)
    }
}

@Suite("Agrupación de la cola")
struct GroupingTests {
    @Test("El badge incluye automatización sin fallas que espera review")
    func badgeIncluyeAutomatizacion() {
        let queue = [
            makePullRequest(requestedFromMe: true, authorLogin: "alice"),
            makePullRequest(requestedFromMe: true, authorLogin: "dependabot", authorTypename: "Bot"),
            makePullRequest(
                requestedFromMe: true,
                authorLogin: "ci-service-user",
                machineAccounts: ["ci-service-user"]
            ),
            makePullRequest(requestedFromMe: false, authorLogin: "bob")
        ]
        #expect(queue.awaitingYourReview.count == 4)
    }

    @Test(
        "Sólo cuentan para el badge las secciones que esperan algo tuyo",
        arguments: [
            (ReviewBucket.needsReview, true),
            (.approvedAlready, false) // tu review es opcional
        ]
    )
    func queSeccionesCuentan(bucket: ReviewBucket, cuenta: Bool) {
        #expect(bucket.needsYourReview == cuenta)
    }

    @Test("Una review pendiente cuenta aunque ya hayas revisado el PR")
    func revisadoAntesCuenta() {
        let queue = [makePullRequest(requestedFromMe: true, reviewedByMe: true)]
        #expect(queue[0].bucket() == .needsReview)
        #expect(queue.awaitingYourReview.count == 1)
    }

    @Test("Automatización se reparte por CI, para bots y cuentas de máquina",
          arguments: [CheckState.success, .failure, .error, .pending, .expected, .unknown], [false, true])
    func automatizacionPorCI(checks: CheckState, machine: Bool) {
        let bot = makePullRequest(checks: checks, authorLogin: "automation",
                                  authorTypename: machine ? "User" : "Bot",
                                  machineAccounts: machine ? ["automation"] : [])
        let human = makePullRequest(checks: checks)
        let queue = [human, bot]
        #expect(queue.reviewSections.count == 1)
        #expect(Set(queue.reviewSections[0].items.map(\.id)) ==
                (checks.isRed ? [human.id] : [human.id, bot.id]))
        #expect(Set(queue.awaitingYourReview.map(\.id)) ==
                Set(queue.reviewSections[0].items.map(\.id)))
        #expect(queue.automation.map(\.id) == (checks.isRed ? [bot.id] : []))
    }

    @Test("Automatización respeta aprobaciones propias y ajenas",
          arguments: [false, true], [false, true])
    func automatizacionAprobada(personal: Bool, global: Bool) {
        let bot = makePullRequest(approvedByMe: personal,
                                  reviewDecision: global ? .approved : .reviewRequired,
                                  authorTypename: "Bot")
        #expect([bot].reviewSections.map(\.bucket) ==
                (personal ? [] : [global ? .approvedAlready : .needsReview]))
        #expect([bot].awaitingYourReview.isEmpty == (personal || global))
        #expect([bot].automation.isEmpty)
    }

    @Test("Los bots listos para mergear no se duplican aunque review no traiga mergeabilidad",
          arguments: [CheckState.success, .failure])
    func prioridadDeMerge(checks: CheckState) {
        let bot = makePullRequest(checks: checks, authorTypename: "Bot",
                                  mergeable: .mergeable,
                                  mergeStateStatus: checks.isRed ? .unstable : .clean)
        let human = makePullRequest(authoredByMe: true, mergeable: .mergeable, mergeStateStatus: .clean)
        let data = [bot, human]
        #expect(data.readyToMerge.count == 2)
        // El snapshot de review conserva el id pero carece de campos de merge.
        let reviewBot = PullRequest(
            id: bot.id, number: bot.number, title: bot.title, url: bot.url,
            repository: bot.repository, baseRefName: bot.baseRefName, headRefName: bot.headRefName,
            author: bot.author, updatedAt: bot.updatedAt, isDraft: false, checks: checks,
            reviewDecision: .reviewRequired, mergeable: nil, mergeStateStatus: nil,
            defaultMergeMethod: nil, authoredByMe: false, requestedFromMe: true,
            reviewedByMe: false, approvals: 0, approvedByMe: false
        )
        let visible = [reviewBot, human].excludingMergeableAutomation(in: data)
        #expect(visible.map(\.id) == [human.id])
        #expect(visible.automation.isEmpty)
        #expect(visible.awaitingYourReview.map(\.id) == [human.id])
        #expect([reviewBot].excludingMergeableAutomation(in: []).count == 1)
    }

    @Test("Automatización con fallas conserva favoritos y actividad reciente")
    func automatizacionFavoritos() {
        let now = Date.now
        let recent = makePullRequest(number: 1, checks: .failure, updatedAt: now, authorTypename: "Bot")
        let old = makePullRequest(number: 2, checks: .error,
                                  updatedAt: now.addingTimeInterval(-3600), authorTypename: "Bot")
        let favorite = makePullRequest(number: 3, repository: "org/favorite", checks: .failure,
                                       updatedAt: now.addingTimeInterval(-7200), authorTypename: "Bot")
        var filter = RepositoryFilter()
        filter.toggleFavorite("org/favorite")
        let ordered = filter.prioritizingFavorites(in: [old, favorite, recent].automation)
        #expect(ordered.map(\.number) == [3, 1, 2])
    }

    @Test("Las secciones salen en orden de prioridad")
    func ordenDeSecciones() {
        let queue = [
            makePullRequest(number: 1, reviewDecision: .approved),
            makePullRequest(number: 2, requestedFromMe: true),
            makePullRequest(number: 3, requestedFromMe: false)
        ]
        #expect(queue.reviewSections.map(\.bucket) == [.needsReview, .approvedAlready])
    }

    @Test("Dentro de una sección, lo más reciente va primero")
    func ordenDentroDeSeccion() {
        let viejo = makePullRequest(
            number: 1,
            requestedFromMe: true,
            updatedAt: .now.addingTimeInterval(-3600)
        )
        let nuevo = makePullRequest(number: 2, requestedFromMe: true)
        #expect([viejo, nuevo].reviewSections[0].items.map(\.number) == [2, 1])
    }
}

@Suite("PRs ignorados")
@MainActor
struct IgnoreListTests {
    /// Defaults aislados por test, para no pisar los de la app real.
    private func makeList() -> IgnoreList {
        let suite = UserDefaults(suiteName: "test-\(UUID().uuidString)")!
        return IgnoreList(defaults: suite)
    }

    @Test("Ignorar y restaurar")
    func ignorarYRestaurar() {
        let list = makeList()
        let pullRequest = makePullRequest()

        #expect(!list.contains(pullRequest))
        list.ignore(pullRequest)
        #expect(list.contains(pullRequest))
        list.restore(pullRequest)
        #expect(!list.contains(pullRequest))
    }

    @Test("Los ids sobreviven a recrear la lista")
    func persistencia() {
        let suite = UserDefaults(suiteName: "test-\(UUID().uuidString)")!
        let pullRequest = makePullRequest()

        IgnoreList(defaults: suite).ignore(pullRequest)
        #expect(IgnoreList(defaults: suite).contains(pullRequest))
    }

    @Test("El badge no cuenta los PRs ignorados")
    func badgeIgnoraLosOcultos() {
        // Es el punto entero: si el badge contara lo que el panel esconde,
        // mostraría un número que no se corresponde con nada visible.
        let visible = makePullRequest(number: 1, requestedFromMe: true, authorLogin: "alice")
        let oculto = makePullRequest(number: 2, requestedFromMe: true, authorLogin: "bob")
        let queue = [visible, oculto]

        #expect(queue.awaitingYourReview.count == 2)
        #expect(queue.excluding([oculto.id]).awaitingYourReview.count == 1)
    }

    @Test("Los ignorados salen de las secciones visibles pero se pueden listar")
    func particion() {
        let a = makePullRequest(number: 1, requestedFromMe: true)
        let b = makePullRequest(number: 2, requestedFromMe: true)
        let queue = [a, b]

        #expect(queue.excluding([b.id]).map(\.number) == [1])
        #expect(queue.only([b.id]).map(\.number) == [2])
    }
}

@Suite("Para mergear")
struct ReadyToMergeTests {
    /// Estados observados en la cola real, con su veredicto esperado.
    /// De 56 PRs: 45 BLOCKED, 4 BEHIND, 3 DIRTY, 3 UNKNOWN, 1 CLEAN.
    @Test(
        "El veredicto sale de mergeStateStatus",
        arguments: [
            (MergeStateStatus.clean, true),
            (.unstable, true), // mergeable: falla un check no requerido
            (.hasHooks, true),
            (.blocked, false), // faltan reviews o checks requeridos
            (.behind, false), // hay que actualizar contra la base
            (.dirty, false), // conflictos
            (.draft, false),
            (.unknown, false) // GitHub todavía no lo calculó
        ]
    )
    func veredictoPorEstado(state: MergeStateStatus, esperado: Bool) {
        let pullRequest = makePullRequest(
            authoredByMe: true,
            mergeable: .mergeable,
            mergeStateStatus: state
        )
        #expect(pullRequest.isReadyToMerge == esperado)
    }

    @Test("Con conflictos no está listo, aunque el estado diga CLEAN")
    func conflictosGanan() {
        let pullRequest = makePullRequest(
            authoredByMe: true,
            mergeable: .conflicting,
            mergeStateStatus: .clean
        )
        #expect(!pullRequest.isReadyToMerge)
    }

    @Test("mergeable UNKNOWN no está listo: GitHub lo calcula diferido")
    func mergeableDesconocido() {
        // Pasa en ~3 de 56 PRs. Se resuelve en el refresh siguiente, no es error.
        let pullRequest = makePullRequest(
            authoredByMe: true,
            mergeable: .unknown,
            mergeStateStatus: .clean
        )
        #expect(!pullRequest.isReadyToMerge)
    }

    @Test("Un draft nunca está listo")
    func draftNoCuenta() {
        let pullRequest = makePullRequest(
            authoredByMe: true,
            isDraft: true,
            mergeable: .mergeable,
            mergeStateStatus: .clean
        )
        #expect(!pullRequest.isReadyToMerge)
    }

    @Test("Sin datos de merge no está listo")
    func sinDatosDeMerge() {
        // La cola de review no pide estos campos, porque calcularlos es caro.
        #expect(!makePullRequest(authoredByMe: true).isReadyToMerge)
    }

    @Test("Haberlo aprobado vos no lo descalifica")
    func haberloAprobadoNoDescalifica() {
        // Aprobar un PR de automatización te saca de sus review requests. Eso no
        // debe hacerlo desaparecer justo cuando se vuelve mergeable.
        let pullRequest = makePullRequest(
            reviewedByMe: true,
            approvedByMe: true,
            reviewDecision: .approved,
            authorLogin: "ci-service-user",
            authorTypename: "User",
            machineAccounts: ["ci-service-user"],
            mergeable: .mergeable,
            mergeStateStatus: .clean
        )
        #expect(pullRequest.isReadyToMerge)
        #expect([pullRequest].readyToMerge.count == 1)
    }

    @Test("La sección lista los tuyos y los de automatización, no los de otros")
    func alcanceDeLaSeccion() {
        let listo: (Int, String, Bool, String?, Set<String>) -> PullRequest = {
            number, login, mine, typename, machineAccounts in
            makePullRequest(
                number: number,
                authorLogin: login,
                authorTypename: typename,
                machineAccounts: machineAccounts,
                authoredByMe: mine,
                mergeable: .mergeable,
                mergeStateStatus: .clean
            )
        }
        let queue = [
            listo(1, "me", true, "User", []), // mío
            listo(2, "dependabot", false, "Bot", []), // automatización
            listo(3, "ci-service-user", false, "User", ["ci-service-user"]),
            listo(4, "alice", false, "User", []) // de otra persona: no es tuyo mergearlo
        ]
        // Como conjunto: el orden lo define updatedAt, y acá son todos iguales.
        #expect(Set(queue.readyToMerge.map(\.number)) == [1, 2, 3])
    }
}

@Suite("Para Fixear")
struct FixQueueTests {
    @Test("Sólo CI fallida o en error necesita un fix",
          arguments: [CheckState.success, .failure, .error, .pending, .expected, .unknown])
    func estadosDeCI(checks: CheckState) {
        let pr = makePullRequest(checks: checks, authoredByMe: true)
        #expect([pr].needingCIFix.map(\.id) == (checks == .failure || checks == .error ? [pr.id] : []))
    }

    @Test("Excluye otros autores, equipos y automatización")
    func soloAutoriaPersonal() {
        let mine = makePullRequest(checks: .failure, authoredByMe: true)
        let other = makePullRequest(requestedFromMe: true, checks: .failure)
        let team = makePullRequest(requestedFromMe: false, checks: .error)
        let bot = makePullRequest(checks: .failure, authorLogin: "dependabot", authorTypename: "Bot")
        let machine = makePullRequest(checks: .failure, authorLogin: "ci-bot",
                                      machineAccounts: ["ci-bot"], authoredByMe: true)
        #expect([mine, other, team, bot, machine].needingCIFix.map(\.id) == [mine.id])
    }

    @Test("No requiere pedidos de review, approvals ni que el PR esté listo")
    func draftPropioConFalla() {
        let pr = makePullRequest(requestedFromMe: false, reviewDecision: nil,
                                 checks: .failure, authoredByMe: true, isDraft: true)
        #expect([pr].needingCIFix.map(\.id) == [pr.id])
    }

    @Test("La CI opcional fallida también aparece aunque permita mergear")
    func mergeableConFalla() {
        let pr = makePullRequest(reviewDecision: .approved, checks: .failure,
                                 authoredByMe: true, mergeable: .mergeable, mergeStateStatus: .unstable)
        #expect([pr].needingCIFix.map(\.id) == [pr.id])
        #expect([pr].readyToMerge.map(\.id) == [pr.id])
    }

    @Test("Respeta ignorados, filtros y orden por actividad")
    func filtrosYOrden() {
        let old = makePullRequest(number: 1, checks: .error,
                                  updatedAt: .now.addingTimeInterval(-3600), authoredByMe: true)
        let recent = makePullRequest(number: 2, checks: .failure, authoredByMe: true)
        let queue = [old, recent]
        #expect(queue.needingCIFix.map(\.id) == [recent.id, old.id])
        #expect(queue.excluding([recent.id]).needingCIFix.map(\.id) == [old.id])
        var filter = RepositoryFilter()
        filter.toggleMute(old.repository)
        #expect(filter.apply(to: queue).needingCIFix.isEmpty)
    }
}

// MARK: - Helper

private func makePullRequest(
    number: Int = 1,
    repository: String = "org/repo",
    requestedFromMe: Bool = false,
    reviewedByMe: Bool = false,
    approvedByMe: Bool = false,
    approvals: Int = 0,
    reviewDecision: ReviewDecision? = .reviewRequired,
    checks: CheckState = .success,
    updatedAt: Date = .now,
    authorLogin: String = "alguien",
    authorTypename: String? = "User",
    machineAccounts: Set<String> = [],
    authoredByMe: Bool = false,
    isDraft: Bool = false,
    mergeable: MergeableState? = nil,
    mergeStateStatus: MergeStateStatus? = nil,
    defaultMergeMethod: MergeMethod? = .squash
) -> PullRequest {
    PullRequest(
        id: "PR_\(number)_\(UUID().uuidString)",
        number: number,
        title: "un cambio",
        url: URL(string: "https://github.com/\(repository)/pull/\(number)")!,
        repository: repository,
        baseRefName: "main",
        headRefName: "una-rama",
        author: Author(
            login: authorLogin,
            typename: authorTypename,
            machineAccounts: machineAccounts
        ),
        updatedAt: updatedAt,
        isDraft: isDraft,
        checks: checks,
        reviewDecision: reviewDecision,
        mergeable: mergeable,
        mergeStateStatus: mergeStateStatus,
        defaultMergeMethod: defaultMergeMethod,
        authoredByMe: authoredByMe,
        requestedFromMe: requestedFromMe,
        reviewedByMe: reviewedByMe,
        approvals: approvals,
        approvedByMe: approvedByMe
    )
}
