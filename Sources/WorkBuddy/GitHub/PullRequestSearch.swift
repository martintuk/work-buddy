import Foundation

/// Búsqueda paginada de PRs. La comparten las colas, que sólo difieren en el
/// filtro de búsqueda y en el tamaño de página que aguanta cada una.
///
/// Está acá y no repetida en cada cola porque el bug que importa —dejar de
/// paginar y truncar resultados en silencio— se arregla en un solo lugar.
enum PullRequestSearch {
    struct Payload: Decodable {
        let viewer: Viewer
        let search: SearchPage
    }

    /// Expuesta para poder fijar la forma de la query en los tests: el filtro es
    /// lo único que decide qué entra y qué no, y un typo ahí no falla, devuelve
    /// menos.
    static func query(search: String, fields: String, pageSize: Int) -> String {
        """
        query($cursor: String, $reviewAuthor: String!) {
          viewer { login }
          search(
            query: "\(search)"
            type: ISSUE
            first: \(pageSize)
            after: $cursor
          ) {
            pageInfo { hasNextPage endCursor }
            nodes { ... on PullRequest { \(fields) } }
          }
        }
        """
    }

    static func fetch(
        search: String,
        fields: String = PullRequestFields.base,
        pageSize: Int,
        maxPages: Int,
        machineAccounts: Set<String> = []
    ) async throws -> [PullRequest] {
        let viewer = try await Viewer.fetch()
        let query = query(search: search, fields: fields, pageSize: pageSize)
        var results: [PullRequest] = []
        var cursor: String?

        for _ in 0 ..< maxPages {
            var arguments = ["api", "graphql", "-f", "query=\(query)",
                             "-f", "reviewAuthor=\(viewer.login)"]
            if let cursor { arguments += ["-F", "cursor=\(cursor)"] }

            let data = try await GH.runRetrying(arguments)
            let payload = try GraphQLResponse<Payload>.decode(data)
            Diagnostics.record(.counts, metrics: [.pages: 1, .items: payload.search.nodes.count])
            let me = payload.viewer.login

            results += payload.search.nodes.compactMap {
                $0?.toPullRequest(me: me, machineAccounts: machineAccounts)
            }

            guard payload.search.pageInfo?.hasNextPage == true,
                  let next = payload.search.pageInfo?.endCursor
            else { return results }
            cursor = next
        }
        return results
    }
}
