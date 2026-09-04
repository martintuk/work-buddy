import Foundation

/// Consulta sólo los PRs propios ya obtenidos por FixQueue. Cada lote trae los
/// hilos y su último comentario, sin descargar cuerpos ni historiales completos.
enum ReplyQueue {
    struct Thread: Decodable {
        let isResolved: Bool
        let comments: Comments

        struct Comments: Decodable {
            let nodes: [Comment]
            struct Comment: Decodable {
                let viewerDidAuthor: Bool
            }
        }

        var needsReply: Bool {
            !isResolved && comments.nodes.last?.viewerDidAuthor == false
        }
    }

    struct Node: Decodable {
        let id: String
        let reviewThreads: Threads

        struct Threads: Decodable {
            let nodes: [Thread]
            let pageInfo: PageInfo
        }
        struct PageInfo: Decodable {
            let hasNextPage: Bool
            let endCursor: String?
        }
    }

    private struct Page {
        let id: String
        let cursor: String?
    }

    static func fetch(
        for pullRequests: [PullRequest],
        run: ([String]) async throws -> Data = { try await GH.runRetrying($0) }
    ) async throws -> [PullRequest] {
        let authored = pullRequests.filter(\.authoredByMe)
        var pending = authored.map { Page(id: $0.id, cursor: nil) }
        var needingReply = Set<String>()

        while !pending.isEmpty {
            try Task.checkCancellation()
            let batch = Array(pending.prefix(25))
            pending.removeFirst(batch.count)
            var variables: [String] = []
            var fields: [String] = []
            var arguments = ["api", "graphql"]
            for (index, page) in batch.enumerated() {
                variables += ["$id\(index): ID!", "$cursor\(index): String"]
                fields.append("""
                pr\(index): node(id: $id\(index)) {
                  ... on PullRequest {
                    id
                    reviewThreads(first: 100, after: $cursor\(index)) {
                      pageInfo { hasNextPage endCursor }
                      nodes {
                        isResolved
                        comments(last: 1) { nodes { viewerDidAuthor } }
                      }
                    }
                  }
                }
                """)
                arguments += ["-f", "id\(index)=\(page.id)"]
                if let cursor = page.cursor {
                    arguments += ["-f", "cursor\(index)=\(cursor)"]
                }
            }
            let query = "query(\(variables.joined(separator: ", "))) { \(fields.joined(separator: "\n")) }"
            arguments += ["-f", "query=\(query)"]
            let payload = try GraphQLResponse<[String: Node?]>.decode(try await run(arguments))
            for (index, page) in batch.enumerated() {
                guard let value = payload["pr\(index)"], let node = value, node.id == page.id else {
                    throw GH.Failure.badJSON("Faltan hilos del PR \(page.id)")
                }
                if node.reviewThreads.nodes.contains(where: \.needsReply) {
                    // Sólo interesa si necesita atención; no contamos los hilos.
                    needingReply.insert(node.id)
                } else if node.reviewThreads.pageInfo.hasNextPage {
                    guard let cursor = node.reviewThreads.pageInfo.endCursor, cursor != page.cursor else {
                        throw GH.Failure.badJSON("Falta el cursor de los hilos del PR \(page.id)")
                    }
                    pending.append(Page(id: node.id, cursor: cursor))
                }
            }
        }
        return authored.filter { needingReply.contains($0.id) }
            .sorted { $0.updatedAt > $1.updatedAt }
    }
}
