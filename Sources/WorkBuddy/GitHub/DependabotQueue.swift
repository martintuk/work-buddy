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
    /// 50 por página con el set completo de campos: verificado 5/5 contra la API
    /// real, ~9s por request.
    ///
    /// Lo que **no** entra es `mergeable`: la misma query con 50 devuelve **502**
    /// de forma consistente, y con 25 anda. Por eso no lo pedimos acá, y por eso
    /// un dependabot listo para mergear llega por `MergeQueue` y no por esta
    /// cola.
    private static let pageSize = 50

    /// Hoy los 50 entran en una página (`hasNextPage: false`). Paginamos igual:
    /// si mañana son 60, truncar en silencio sería exactamente el modo de falla
    /// que esta app trata de no tener.
    private static let maxPages = 4

    /// Complemento exacto de `ReviewQueue.searchQuery`.
    static let baseSearchQuery =
        "is:open is:pr review-requested:@me archived:false author:app/dependabot"

    static func searchQuery(configuration: AppConfiguration) -> String {
        configuration.scopedSearch(baseSearchQuery)
    }

    static func fetch(configuration: AppConfiguration = .empty) async throws -> [PullRequest] {
        try await PullRequestSearch.fetch(
            search: searchQuery(configuration: configuration),
            pageSize: pageSize,
            maxPages: maxPages,
            machineAccounts: configuration.machineAccounts
        )
    }
}
