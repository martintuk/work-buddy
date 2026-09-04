import Foundation

/// Estado agregado de los checks de CI del último commit.
enum CheckState: String, Sendable {
    case success = "SUCCESS"
    case failure = "FAILURE"
    case error = "ERROR"
    case pending = "PENDING"
    case expected = "EXPECTED"
    case unknown

    /// Ojo: `statusCheckRollup` incluye checks **opcionales**, así que esto sirve
    /// como badge informativo, no como filtro. Medido sobre datos reales, usarlo
    /// para esconder PRs tapaba 40 de 63 — muchas seguían necesitando review.
    var isRed: Bool { self == .failure || self == .error }
}

/// Decisión de review agregada que reporta GitHub.
enum ReviewDecision: String, Sendable {
    case approved = "APPROVED"
    case changesRequested = "CHANGES_REQUESTED"
    case reviewRequired = "REVIEW_REQUIRED"
}

/// Si la rama se puede fusionar sin conflictos.
enum MergeableState: String, Sendable {
    case mergeable = "MERGEABLE"
    case conflicting = "CONFLICTING"
    /// GitHub lo calcula de forma diferida: la primera consulta puede devolver
    /// UNKNOWN y resolverse en la siguiente. Medido, pasa en ~3 de 56 PRs.
    case unknown = "UNKNOWN"
}

/// Veredicto de GitHub sobre si el botón de merge estaría habilitado.
enum MergeStateStatus: String, Sendable {
    /// Todo en orden.
    case clean = "CLEAN"
    /// Mergeable, pero falla algún check **no requerido**.
    case unstable = "UNSTABLE"
    /// Limpio, con pre-receive hooks configurados.
    case hasHooks = "HAS_HOOKS"
    /// Faltan reviews o checks requeridos. Es el estado más común en la cola.
    case blocked = "BLOCKED"
    /// Hay que actualizar la rama contra la base.
    case behind = "BEHIND"
    /// Conflictos.
    case dirty = "DIRTY"
    case draft = "DRAFT"
    case unknown = "UNKNOWN"
}

/// En qué cola cae un PR. El orden del `case` es el orden de prioridad.
enum ReviewBucket: Int, CaseIterable, Sendable {
    /// Te lo pidieron a vos y todavía no lo miraste.
    case blocksYou
    /// Ya lo revisaste y volvió a tu cola.
    case revisited
    /// Se lo pidieron a un equipo tuyo: lo puede agarrar cualquiera.
    case teamQueue
    /// GitHub ya lo considera aprobado, así que tu review es opcional. Sigue
    /// apareciendo porque todavía figurás como reviewer.
    case approvedAlready
    /// Sin actividad hace más de 30 días. Probablemente abandonado.
    case zombie

    var title: String {
        switch self {
        case .blocksYou: "Para revisar"
        case .revisited: "Volvieron a vos"
        case .teamQueue: "Cola del equipo"
        case .approvedAlready: "Ya aprobados"
        case .zombie: "Zombies"
        }
    }

    /// La sección espera una acción **tuya**, no de otra persona ni de nadie.
    ///
    /// `teamQueue` queda afuera porque la puede agarrar cualquiera del equipo;
    /// `approvedAlready` porque tu review es opcional; `zombie` porque nadie
    /// espera nada.
    var needsYourReview: Bool {
        switch self {
        case .blocksYou, .revisited: true
        case .teamQueue, .approvedAlready, .zombie: false
        }
    }

    /// Aclaración para las secciones cuyo nombre no se explica solo.
    var subtitle: String? {
        switch self {
        case .approvedAlready: "tu review es opcional, ya tienen los approvals"
        case .zombie: "sin actividad hace más de 30 días"
        case .teamQueue: "se lo pidieron a un equipo tuyo"
        case .blocksYou, .revisited: nil
        }
    }
}

/// Quién abrió el PR.
struct Author: Sendable {
    let login: String
    /// `true` si GitHub lo tipa como `Bot`, o si la configuración lo declara
    /// como cuenta de máquina.
    let isBot: Bool

    init(login: String, typename: String?, machineAccounts: Set<String> = []) {
        self.login = login
        isBot = typename == "Bot" || machineAccounts.contains(login.lowercased())
    }
}

struct PullRequest: Identifiable, Sendable {
    let id: String
    let number: Int
    let title: String
    let url: URL
    let repository: String
    /// Rama contra la que se mergea.
    let baseRefName: String
    /// Rama del PR.
    let headRefName: String
    let author: Author
    let updatedAt: Date
    let isDraft: Bool
    let checks: CheckState
    let reviewDecision: ReviewDecision?

    /// Sólo se piden en la query de "listos para mergear": calcularlos es caro.
    let mergeable: MergeableState?
    let mergeStateStatus: MergeStateStatus?

    /// El método que GitHub usaría en la web para este repo. No lo elegís vos: si
    /// el repo habilita sólo squash, la web muestra un botón y acá también.
    let defaultMergeMethod: MergeMethod?

    /// Lo abriste vos.
    let authoredByMe: Bool

    /// El review te lo pidieron a vos, no sólo a un equipo del que sos parte.
    /// Es la señal que más ordena la cola: parte los 63 casi por la mitad.
    let requestedFromMe: Bool
    /// Ya dejaste un review en este PR.
    let reviewedByMe: Bool
    let approvals: Int

    static let zombieThreshold: TimeInterval = 30 * 24 * 60 * 60

    /// GitHub habilitaría el botón de merge ahora mismo.
    ///
    /// Es el veredicto de GitHub y no una reconstrucción nuestra: `BLOCKED` ya
    /// contempla reviews y checks requeridos, CODEOWNERS y branch protection.
    /// Reconstruirlo a mano fue exactamente el bug que tuvimos con los approvals.
    ///
    /// `UNSTABLE` cuenta como listo porque GitHub deja mergear: significa que
    /// falla un check **no requerido**. La fila lo muestra con el badge de CI.
    var isReadyToMerge: Bool {
        guard !isDraft, mergeable == .mergeable else { return false }
        switch mergeStateStatus {
        case .clean, .unstable, .hasHooks:
            return true
        // BEHIND, BLOCKED, DIRTY, DRAFT, UNKNOWN y nil no están listos. UNKNOWN
        // no es un error: GitHub todavía no terminó de calcularlo y se resuelve
        // en el refresh siguiente.
        default:
            return false
        }
    }

    /// GitHub no deja aprobar tus propios PRs. Ofrecer el botón igual sólo
    /// entrenaría a ignorar errores.
    var canApprove: Bool { !authoredByMe }

    /// Se puede mergear **y** sabemos con qué método. Las dos condiciones salen
    /// de GitHub; si falta cualquiera, no ofrecemos la acción.
    var canMerge: Bool { isReadyToMerge && defaultMergeMethod != nil }

    /// Nombre del repo sin la organización: en una lista de un solo org, el
    /// prefijo se repite en todas las filas y no aporta nada.
    var shortRepository: String {
        repository.split(separator: "/").last.map(String.init) ?? repository
    }

    /// `reviewDecision` es la única fuente de verdad sobre si un PR está
    /// aprobado: contempla las reglas de branch protection y CODEOWNERS.
    ///
    /// Acá antes había un `approvals > 0`, y estaba mal: en la cola real hay un
    /// PR con **3 approvals** que GitHub sigue marcando `REVIEW_REQUIRED` (falta
    /// un CODEOWNER, o los approvals quedaron viejos tras nuevos commits).
    /// Contar approvals a mano lo habría archivado como "ya cubierto" cuando
    /// todavía necesita review. `approvals` queda sólo como badge.
    func bucket(now: Date = .now) -> ReviewBucket {
        if now.timeIntervalSince(updatedAt) > Self.zombieThreshold { return .zombie }
        if reviewDecision == .approved { return .approvedAlready }
        if requestedFromMe { return reviewedByMe ? .revisited : .blocksYou }
        return .teamQueue
    }
}

// MARK: - Agrupaciones

/// Viven acá y no en el store para que sean funciones puras sobre un array:
/// se pueden testear sin instanciar nada ni abrir un seam de test.
extension [PullRequest] {
    /// Saca los PRs con estos ids. Se compone antes de agrupar, así el filtro de
    /// ignorados vale también para el contador del badge.
    func excluding(_ ids: Set<String>) -> [PullRequest] {
        filter { !ids.contains($0.id) }
    }

    /// Deja sólo los PRs con estos ids.
    func only(_ ids: Set<String>) -> [PullRequest] {
        filter { ids.contains($0.id) }
    }

    /// PRs de personas, agrupados por bucket en orden de prioridad.
    var humanSections: [(bucket: ReviewBucket, items: [PullRequest])] {
        let humans = filter { !$0.author.isBot }
        let grouped = Dictionary(grouping: humans) { $0.bucket() }
        return ReviewBucket.allCases.compactMap { bucket in
            guard let items = grouped[bucket], !items.isEmpty else { return nil }
            return (bucket, items.sorted { $0.updatedAt > $1.updatedAt })
        }
    }

    /// Lo que abrieron bots o cuentas de máquina. Va aparte, colapsado.
    var automation: [PullRequest] {
        filter(\.author.isBot).sorted { $0.updatedAt > $1.updatedAt }
    }

    /// PRs que GitHub dejaría mergear y que te toca mergear a vos: los tuyos y
    /// los de automatización. Los de otras personas son de ellas para mergear,
    /// aunque estén aprobados.
    var readyToMerge: [PullRequest] {
        filter { ($0.authoredByMe || $0.author.isBot) && $0.isReadyToMerge }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    /// PRs de personas que esperan que los revises vos.
    ///
    /// Los de automatización quedan afuera a propósito: si el badge contara los
    /// 56 PRs de bots de la cola, dejarías de mirarlo.
    var awaitingYourReview: [PullRequest] {
        filter { !$0.author.isBot && $0.bucket().needsYourReview }
    }
}
