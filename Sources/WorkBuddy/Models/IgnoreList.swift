import Foundation

/// PRs que decidiste no ver más.
///
/// Guarda el node id global de GitHub (`PR_kwDO…`), que es estable: no cambia
/// si el PR se renombra ni si cambia de base branch.
@MainActor
@Observable
final class IgnoreList {
    private static let key = "ignoredPullRequestIDs"

    private let defaults: UserDefaults
    private(set) var ids: Set<String>

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        ids = Set(defaults.stringArray(forKey: Self.key) ?? [])
    }

    func contains(_ pullRequest: PullRequest) -> Bool {
        ids.contains(pullRequest.id)
    }

    func ignore(_ pullRequest: PullRequest) {
        guard ids.insert(pullRequest.id).inserted else { return }
        persist()
    }

    func restore(_ pullRequest: PullRequest) {
        guard ids.remove(pullRequest.id) != nil else { return }
        persist()
    }

    // No purgamos los ids de PRs ya cerrados: para saber si siguen abiertos
    // habría que consultarlos, y un id de más cuesta ~50 bytes. Purgar contra la
    // cola actual sería un bug, porque la query excluye dependabot y volverían a
    // aparecer los que ignoraste de ahí.
    private func persist() {
        defaults.set(Array(ids), forKey: Self.key)
    }
}
