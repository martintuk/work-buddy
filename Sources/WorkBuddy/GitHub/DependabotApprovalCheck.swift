import Foundation

/// Lectura individual antes de cada aprobación. No reutiliza el refresh de la cola.
enum DependabotApprovalCheck {
    struct Snapshot: Sendable {
        let viewer: String
        let pullRequest: PullRequest?
        let isOpen: Bool
    }

    static func fetch(
        _ pullRequest: PullRequest, viewer: String,
        request: @Sendable ([String]) async throws -> Data = { try await GH.runRetrying($0) }
    ) async throws -> Snapshot {
        struct Payload: Decodable {
            let viewer: Viewer
            let node: Node?
            struct Node: Decodable {
                let state: String
                let pullRequest: PullRequestNode
                init(from decoder: Decoder) throws {
                    struct State: Decodable { let state: String }
                    state = try State(from: decoder).state
                    pullRequest = try PullRequestNode(from: decoder)
                }
            }
        }
        let query = """
        query($id: ID!, $reviewAuthor: String!) {
          viewer { login }
          node(id: $id) {
            ... on PullRequest { state \(PullRequestFields.withMergeability) }
          }
        }
        """
        let data = try await request([
            "api", "graphql", "-f", "query=\(query)",
            "-f", "id=\(pullRequest.id)", "-f", "reviewAuthor=\(viewer)"
        ])
        let payload = try GraphQLResponse<Payload>.decode(data)
        return Snapshot(viewer: payload.viewer.login,
                        pullRequest: payload.node?.pullRequest.toPullRequest(me: payload.viewer.login),
                        isOpen: payload.node?.state == "OPEN")
    }
}
