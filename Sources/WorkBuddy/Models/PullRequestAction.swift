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
    /// Sin método: lo define el repo vía `PullRequest.defaultMergeMethod`.
    case merge

    var id: Self { self }

    var title: String {
        switch self {
        case .open: "Abrir en el navegador"
        case .ignore: "Ignorar"
        case .restore: "Dejar de ignorar"
        case .approve: "Aprobar"
        case .rebase: "Rebasear"
        case .merge: "Mergear"
        }
    }

    var systemImage: String {
        switch self {
        case .open: "arrow.up.forward.square"
        case .ignore: "eye.slash"
        case .restore: "eye"
        case .approve: "checkmark.circle"
        case .rebase: "arrow.triangle.2.circlepath"
        case .merge: "arrow.triangle.merge"
        }
    }

    /// Las que escriben en GitHub. Las locales se aplican al instante; éstas
    /// pueden fallar y tardan.
    var writesToGitHub: Bool {
        switch self {
        case .approve, .merge, .rebase: true
        case .open, .ignore, .restore: false
        }
    }

    /// Irreversible y pública: pide confirmación antes de correrse.
    var needsConfirmation: Bool { self == .merge }
}
