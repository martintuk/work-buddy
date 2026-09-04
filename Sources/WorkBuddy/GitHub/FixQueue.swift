import Foundation

/// PRs abiertos de tu autoría. La política de dominio selecciona los de CI roja.
/// Se pagina aparte: no dependen de un pedido de review ni del límite de candidatos
/// de MergeQueue. No se calcula mergeabilidad para encontrar fallas de CI.
enum FixQueue {
    static let baseSearchQuery = "is:open is:pr author:@me archived:false"

    static func searchQuery(configuration: AppConfiguration) -> String {
        configuration.scopedSearch(baseSearchQuery)
    }

    static func fetch(configuration: AppConfiguration = .empty) async throws -> [PullRequest] {
        try await PullRequestSearch.fetch(
            search: searchQuery(configuration: configuration),
            pageSize: 25,
            maxPages: 20,
            machineAccounts: configuration.machineAccounts
        )
    }
}
