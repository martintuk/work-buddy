import Foundation

/// Consulta hilos en lotes. En PRs ajenos recorre hacia atrás hasta encontrar una
/// mención o un comentario propio seguido de respuestas; las páginas se piden sólo si hacen falta.
enum ReplyQueue {
    struct Result: Sendable {
        let needingReply: [PullRequest]
        let waitingForReply: [PullRequest]
    }

    struct PageInfo: Decodable {
        let hasNextPage: Bool?
        let endCursor: String?
        let hasPreviousPage: Bool?
        let startCursor: String?
    }

    struct Comments: Decodable {
        let nodes: [Comment]
        let pageInfo: PageInfo
    }

    struct Comment: Decodable {
        let viewerDidAuthor: Bool
        let bodyHTML: String
        let state: String

        /// GitHub marca las menciones reales en el HTML renderizado. Esto evita
        /// confundir @me con @me-other, una dirección de email o código literal.
        func mentions(_ login: String) -> Bool {
            guard !login.isEmpty else { return false }
            let user = NSRegularExpression.escapedPattern(for: login)
            let pattern = "(?is)<a\\b(?=[^>]*\\bclass\\s*=\\s*[\"'][^\"']*\\buser-mention\\b[^\"']*[\"'])[^>]*>\\s*@\(user)\\s*</a>"
            return bodyHTML.range(of: pattern, options: .regularExpression) != nil
        }
    }

    struct Thread: Decodable {
        let id: String
        let isResolved: Bool
        let comments: Comments

        enum Attention: Equatable {
            case none, needsReply, waitingForReply, olderComments
        }

        func attention(authoredByMe: Bool, me: String, hasNewerComments: Bool = false) -> Attention {
            guard !isResolved else { return .none }
            let published = comments.nodes.filter { $0.state == "SUBMITTED" }
            if authoredByMe, let last = published.last {
                return last.viewerDidAuthor ? .none : .needsReply
            }
            if !authoredByMe {
                if !hasNewerComments, published.last?.viewerDidAuthor == true {
                    return .waitingForReply
                }
                // Si el último no es mío, cualquier comentario propio ya tuvo respuesta.
                if published.contains(where: { $0.viewerDidAuthor || $0.mentions(me) }) {
                    return .needsReply
                }
            }
            return comments.pageInfo.hasPreviousPage == true ? .olderComments : .none
        }
    }

    private struct Node: Decodable {
        let id: String
        let reviewThreads: Threads?
        let isResolved: Bool?
        let comments: Comments?

        struct Threads: Decodable {
            let nodes: [Thread]
            let pageInfo: PageInfo
        }
    }

    private struct Page {
        let prID: String
        let threadID: String?
        let cursor: String?
        var hasNewerComments = false
        var nodeID: String { threadID ?? prID }
    }

    private static let commentFields = """
    pageInfo { hasPreviousPage startCursor }
    nodes { viewerDidAuthor bodyHTML state }
    """

    static func fetch(
        for pullRequests: [PullRequest],
        me: String,
        run: ([String]) async throws -> Data = { try await GH.runRetrying($0) }
    ) async throws -> Result {
        var seen = Set<String>()
        let candidates = pullRequests.filter { seen.insert($0.id).inserted }
        let ownIDs = Set(candidates.filter(\.authoredByMe).map(\.id))
        Diagnostics.record(.counts, metrics: [.candidates: candidates.count])
        var pending = candidates.map { Page(prID: $0.id, threadID: nil, cursor: nil) }
        var needingReply = Set<String>()
        var waitingForReply = Set<String>()

        while !pending.isEmpty {
            try Task.checkCancellation()
            // Máximo 10 x 50 x 20 comentarios por request inicial.
            let batch = Array(pending.prefix(10))
            Diagnostics.record(.counts, metrics: [.batchSize: batch.count, .pages: 1])
            pending.removeFirst(batch.count)
            var variables: [String] = []
            var fields: [String] = []
            var arguments = ["api", "graphql"]
            for (index, page) in batch.enumerated() {
                variables += ["$id\(index): ID!", "$cursor\(index): String"]
                let fragment: String
                if page.threadID != nil {
                    fragment = """
                    ... on PullRequestReviewThread {
                      id isResolved
                      comments(last: 20, before: $cursor\(index)) { \(commentFields) }
                    }
                    """
                } else {
                    fragment = """
                    ... on PullRequest {
                      id
                      reviewThreads(first: 50, after: $cursor\(index)) {
                        pageInfo { hasNextPage endCursor }
                        nodes {
                          id isResolved
                          comments(last: 20) { \(commentFields) }
                        }
                      }
                    }
                    """
                }
                fields.append("pr\(index): node(id: $id\(index)) { \(fragment) }")
                arguments += ["-f", "id\(index)=\(page.nodeID)"]
                if let cursor = page.cursor {
                    arguments += ["-f", "cursor\(index)=\(cursor)"]
                }
            }
            let query = "query(\(variables.joined(separator: ", "))) { \(fields.joined(separator: "\n")) }"
            arguments += ["-f", "query=\(query)"]
            let payload = try GraphQLResponse<[String: Node?]>.decode(try await run(arguments))
            for (index, page) in batch.enumerated() {
                guard let value = payload["pr\(index)"], let node = value, node.id == page.nodeID else {
                    throw GH.Failure.missingThreads(page.prID)
                }
                let threads: [Thread]
                if page.threadID != nil {
                    guard let comments = node.comments, let isResolved = node.isResolved else {
                        throw GH.Failure.missingComments(node.id)
                    }
                    threads = [Thread(id: node.id, isResolved: isResolved, comments: comments)]
                } else {
                    guard let connection = node.reviewThreads else {
                        throw GH.Failure.missingThreads(node.id)
                    }
                    threads = connection.nodes
                    if connection.pageInfo.hasNextPage == true {
                        let cursor = try nextCursor(connection.pageInfo.endCursor, previous: page.cursor)
                        pending.append(Page(prID: page.prID, threadID: nil, cursor: cursor))
                    }
                }
                for thread in threads {
                    switch thread.attention(authoredByMe: ownIDs.contains(page.prID), me: me,
                                            hasNewerComments: page.hasNewerComments) {
                    case .needsReply: needingReply.insert(page.prID)
                    case .waitingForReply: waitingForReply.insert(page.prID)
                    case .none: break
                    case .olderComments:
                        let cursor = try nextCursor(thread.comments.pageInfo.startCursor,
                                                    previous: page.threadID == nil ? nil : page.cursor)
                        pending.append(Page(prID: page.prID, threadID: thread.id, cursor: cursor,
                                            hasNewerComments: page.hasNewerComments
                                                || thread.comments.nodes.contains { $0.state == "SUBMITTED" }))
                    }
                }
            }
            // En PRs propios basta un hilo pendiente. En ajenos puede haber
            // un hilo para responder y otro esperando respuesta.
            pending.removeAll { page in
                needingReply.contains(page.prID)
                    && (ownIDs.contains(page.prID) || waitingForReply.contains(page.prID))
            }
        }
        return Result(
            needingReply: candidates.filter { needingReply.contains($0.id) }
                .sorted { $0.updatedAt > $1.updatedAt },
            waitingForReply: candidates.filter { waitingForReply.contains($0.id) }
                .sorted { $0.updatedAt > $1.updatedAt }
        )
    }

    private static func nextCursor(_ cursor: String?, previous: String?) throws -> String {
        guard let cursor, cursor != previous else {
            throw GH.Failure.missingConversationCursor
        }
        return cursor
    }
}
