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

    /// Sólo se piden en la query de "Para mergear": calcularlos es caro.
    let mergeable: MergeableState?
    let mergeStateStatus: MergeStateStatus?

    /// El método que GitHub usaría en la web para este repo. No lo elegís vos: si
    /// el repo habilita sólo squash, la web muestra un botón y acá también.
    let defaultMergeMethod: MergeMethod?

    /// Lo abriste vos.
    let authoredByMe: Bool

    /// Pedido directo a vos. Los pedidos a tus equipos tienen la misma prioridad.
    let requestedFromMe: Bool
    /// Ya dejaste un review en este PR.
    let reviewedByMe: Bool
    let approvals: Int
    /// Tu última decisión de review es APPROVED y no fue descartada.
    let approvedByMe: Bool

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

    /// Clasifica un PR que pertenece a la cola de pedidos de review.
    func bucket() -> ReviewBucket? {
        PullRequestQueuePolicy.reviewBucket(for: self)
    }
}
