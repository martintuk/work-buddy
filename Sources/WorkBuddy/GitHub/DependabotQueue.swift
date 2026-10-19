import Foundation

/// Trae los PRs de dependabot donde te pidieron review.
///
/// **El alcance sale gratis, y por eso no hay lista de repos.**
/// `review-requested:@me` incluye los pedidos que te llegan *vía equipo*, no
/// sólo los directos: medido, 50 PRs de dependabot contra 21 con
/// `user-review-requested:@me`, que es la variante solo-directos. O sea que la
/// lista de repos relevantes ya la mantienen CODEOWNERS y la pertenencia a
/// equipos.
///
/// Contra una whitelist a mano esto midió mejor: evita mantener una segunda
/// fuente de verdad que se desactualiza cuando cambian los equipos o repos.
enum DependabotQueue {
    /// Confirmar ausencia de conflictos exige `mergeable`. Con 50 PRs produce
    /// 502; con 25 funciona (ver docs/assumptions.md).
    private static let pageSize = 25

    /// Conserva la capacidad anterior de 200 PRs al reducir el tamaño de página.
    private static let maxPages = 8

    /// Complemento exacto de `ReviewQueue.searchQuery`.
    static let baseSearchQuery =
        "is:open is:pr review-requested:@me archived:false author:app/dependabot"

    static func searchQuery(configuration: AppConfiguration) -> String {
        configuration.scopedSearch(baseSearchQuery)
    }

    static func fetch(
        configuration: AppConfiguration = .empty, viewer: Viewer,
        request: @Sendable ([String]) async throws -> Data = { try await GH.runRetrying($0) }
    ) async throws -> [PullRequest] {
        try await PullRequestSearch.fetch(
            viewer: viewer,
            search: searchQuery(configuration: configuration),
            fields: PullRequestFields.withMergeability,
            pageSize: pageSize,
            maxPages: maxPages,
            machineAccounts: configuration.machineAccounts,
            request: request
        )
    }
}
