import Foundation

/// Método de merge. El `rawValue` es el flag de `gh pr merge`.
///
/// No lo elegís vos: sale de `viewerDefaultMergeMethod`, que es el método que
/// GitHub te daría en la web. En estos repos es siempre `SQUASH`, porque es el
/// único habilitado, y ahí la web muestra un solo botón.
enum MergeMethod: String, CaseIterable, Sendable {
    case squash
    case merge
    case rebase

    var title: String {
        switch self {
        case .squash: L10n.text(.mergeSquash)
        case .merge: L10n.text(.mergeCommit)
        case .rebase: L10n.text(.mergeRebase)
        }
    }

    /// Convierte el enum de GraphQL. Un valor nuevo devuelve `nil`, y entonces la
    /// app no ofrece mergear: preferimos no ofrecerlo antes que adivinar.
    init?(graphQL value: String) {
        switch value {
        case "SQUASH": self = .squash
        case "MERGE": self = .merge
        case "REBASE": self = .rebase
        default: return nil
        }
    }
}

/// Las únicas escrituras que la app hace contra GitHub.
///
/// Los argumentos están declarados como plantilla y no se arman sobre la marcha:
/// así una acción nueva no puede convertirse por descuido en una invocación
/// arbitraria de `gh`. Un PR por llamada, sin batching.
enum GitHubWrite: Sendable {
    case approve(repository: String, number: Int)
    case rebase(repository: String, number: Int)
    case dependabotRebase(repository: String, number: Int)
    case merge(repository: String, number: Int, method: MergeMethod)

    var arguments: [String] {
        switch self {
        // Sin `--body`: es una aprobación sin comentario. `gh pr review
        // --approve` cuenta como review event, así que satisface una regla de
        // required reviewers.
        case .approve(let repository, let number):
            ["pr", "review", String(number), "--repo", repository, "--approve"]

        // Actualiza la rama y mantiene el PR abierto. Sin --rebase, GitHub
        // crearía un commit de merge en vez de rebasear.
        case .rebase(let repository, let number):
            ["pr", "update-branch", String(number), "--repo", repository, "--rebase"]

        // Dependabot interpreta este comentario como una orden. Es una
        // escritura y no una operación local sobre la rama.
        case .dependabotRebase(let repository, let number):
            ["pr", "comment", String(number), "--repo", repository,
             "--body", "@dependabot rebase"]

        // El método va siempre explícito: `gh pr merge` sin flag pregunta de
        // forma interactiva, y preguntar dentro de un subproceso cuelga.
        //
        // Tampoco usamos `--auto`: el auto-merge está deshabilitado en estos
        // repos, así que armarlo para después nunca funcionó. Un merge común sí,
        // y no es menos seguro: GitHub valida la mergeabilidad server-side en el
        // momento del merge, así que un PR que se puso en rojo desde el último
        // refresh es **rechazado**, no mergeado. La data vieja falla cerrada.
        case .merge(let repository, let number, let method):
            ["pr", "merge", String(number), "--repo", repository, "--\(method.rawValue)"]
        }
    }

    /// Lo que la acción hizo, en pasado, para el aviso al usuario.
    var pastTense: String {
        switch self {
        case .approve: L10n.text(.prApproved)
        case .rebase: L10n.text(.prRebased)
        case .dependabotRebase: L10n.text(.prDependabotRequested)
        case .merge: L10n.text(.prMerged)
        }
    }
}
