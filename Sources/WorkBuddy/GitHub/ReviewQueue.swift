import Foundation

/// Trae los PRs **de personas** donde te pidieron review, en todos los repos.
///
/// Va por GraphQL y no por `gh search prs` por dos razones medidas:
///
/// 1. **Rate limit.** La API de search REST permite 30 req/min y se comparte con
///    todo lo demás. GraphQL tiene un presupuesto de 5000 puntos/hora, así que
///    una app que hace polling no lo agota.
/// 2. **Una sola ida y vuelta.** La misma query trae review requests, reviews y
///    estado de CI. Con `gh search prs` haría falta una llamada extra por PR.
enum ReviewQueue {
    /// 25 y no más: con conexiones anidadas, `first: 100` hace que GitHub
    /// devuelva **502**. Verificado contra la API real. (`first: 50` también
    /// anda —lo mide `DependabotQueue`— pero acá quedan 7 PRs, así que el
    /// tamaño de página no cambia nada.)
    private static let pageSize = 25

    /// Tope de páginas, para que una cola gigante no cuelgue la app.
    private static let maxPages = 20

    /// Dependabot es el 88% del volumen de la cola (50 de 57 cuando lo medimos),
    /// y tiene su propia query en `DependabotQueue`. Acá lo excluimos para que
    /// esta cola quepa en una página: los dos filtros son **complementarios
    /// exactos**, así que entre las dos no se pierde ni se duplica nada.
    ///
    /// El resto de la automatización (cuentas de máquina, otros bots) sí viene
    /// por acá y se clasifica en el cliente vía `Author.isBot`.
    static let baseSearchQuery =
        "is:open is:pr review-requested:@me archived:false -author:app/dependabot"

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
