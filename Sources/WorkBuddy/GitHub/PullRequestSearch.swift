import Foundation

/// Shared paginated PR search. Queues vary by filter and supported page size.
/// Keeping pagination here avoids fixing silent truncation separately in every queue.
enum PullRequestSearch {
    struct Payload: Decodable {
        let viewer: Viewer
        let search: SearchPage
    }

    /// Expose query construction for contract tests. A filter typo can silently
    /// return fewer results instead of failing.
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
        viewer: Viewer,
        search: String,
        fields: String = PullRequestFields.base,
        pageSize: Int,
        maxPages: Int,
        machineAccounts: Set<String> = [],
        request: @Sendable ([String]) async throws -> Data = { try await GH.runRetrying($0) }
    ) async throws -> [PullRequest] {
        let query = query(search: search, fields: fields, pageSize: pageSize)
        var results: [PullRequest] = []
        var cursor: String?

        for _ in 0 ..< maxPages {
            try Task.checkCancellation()
            var arguments = ["api", "graphql", "-f", "query=\(query)",
                             "-f", "reviewAuthor=\(viewer.login)"]
            if let cursor { arguments += ["-F", "cursor=\(cursor)"] }

            let data = try await request(arguments)
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
