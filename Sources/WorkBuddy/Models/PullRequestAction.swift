import Foundation

/// Acciones que el panel puede correr sobre un PR.
///
/// Algunas son locales (ignorar) y otras van a pegarle a GitHub (aprobar,
/// comentar, mergear). El panel sólo declara la intención: quién la ejecuta y
/// cómo es responsabilidad del store, así una acción nueva no toca las vistas.
enum PullRequestAction: Identifiable, Hashable, Sendable {
    case open
    case ignore
    case restore
    case approve
    case rebase
    case dependabotRebase
    /// Sin método: lo define el repo vía `PullRequest.defaultMergeMethod`.
    case merge

    var id: Self { self }

    var title: String {
        switch self {
        case .open: L10n.text(.prOpen)
        case .ignore: L10n.text(.prIgnore)
        case .restore: L10n.text(.prRestore)
        case .approve: L10n.text(.prApprove)
        case .rebase: L10n.text(.prRebase)
        case .dependabotRebase: L10n.text(.prDependabotRebase)
        case .merge: L10n.text(.prMerge)
        }
    }

    var systemImage: String {
        switch self {
        case .open: "arrow.up.forward.square"
        case .ignore: "eye.slash"
        case .restore: "eye"
        case .approve: "checkmark.circle"
        case .rebase: "arrow.triangle.2.circlepath"
        case .dependabotRebase: "bubble.left"
        case .merge: "arrow.triangle.merge"
        }
    }

    /// Las que escriben en GitHub pueden fallar y tardar después de confirmar.
    var writesToGitHub: Bool {
        switch self {
        case .approve, .rebase, .dependabotRebase, .merge: true
        case .open, .ignore, .restore: false
        }
    }

    var completedText: String {
        switch self {
        case .approve: L10n.text(.prApproved)
        case .merge: L10n.text(.prMerged)
        case .rebase: L10n.text(.prRebased)
        case .dependabotRebase: L10n.text(.prDependabotRequested)
        default: L10n.text(.activityCompleted)
        }
    }

    var batchAction: PullRequestBatchAction? {
        switch self { case .approve: .approve; case .merge: .merge; default: nil }
    }

    var needsConfirmation: Bool {
        switch self {
        case .open, .ignore, .restore: false
        case .approve, .rebase, .dependabotRebase, .merge: true
        }
    }
}

extension PullRequest {
    /// La misma disponibilidad para los dos menús y para ejecutar una escritura.
    func availableWriteActions(behindBy: Int?) -> [PullRequestAction] {
        var actions: [PullRequestAction] = []
        if canRequestDependabotRebase(behindBy: behindBy) { actions.append(.dependabotRebase) }
        if canApprove { actions.append(.approve) }
        if canRebase(behindBy: behindBy) { actions.append(.rebase) }
        if canMerge { actions.append(.merge) }
        return actions
    }
}

/// Guarda la intención, no una copia del PR que puede quedar vieja durante un refresh.
struct PendingPullRequestAction {
    let pullRequestID: PullRequest.ID
    let action: PullRequestAction
    /// Si cambia el método mostrado, hace falta una nueva confirmación.
    let mergeMethod: MergeMethod?

    init(action: PullRequestAction, pullRequest: PullRequest) {
        pullRequestID = pullRequest.id
        self.action = action
        mergeMethod = action == .merge ? pullRequest.defaultMergeMethod : nil
    }

    func isAvailable(for pullRequest: PullRequest?, behindBy: Int?) -> Bool {
        guard let pullRequest, pullRequest.id == pullRequestID,
              pullRequest.availableWriteActions(behindBy: behindBy).contains(action) else { return false }
        return action != .merge || mergeMethod == pullRequest.defaultMergeMethod
    }
}
