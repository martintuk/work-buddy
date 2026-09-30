import Foundation

/// Lectura individual antes de cada acción. No reutiliza el refresh de la cola.
enum PullRequestActionCheck {
    struct Snapshot: Sendable {
        let viewer: String
        let pullRequest: PullRequest?
        let isOpen: Bool
        var isMerged = false
    }

    static func fetch(
        _ pullRequest: PullRequest, viewer: String, action: PullRequestBatchAction = .approve,
        machineAccounts: Set<String> = [],
        request: @Sendable ([String]) async throws -> Data = { try await GH.runAPI($0, retryingRead: true) }
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
        let fields = action == .merge ? PullRequestFields.withMergeState : PullRequestFields.withMergeability
        let query = """
        query($id: ID!, $reviewAuthor: String!) {
          viewer { login }
          node(id: $id) {
            ... on PullRequest { state \(fields) }
          }
        }
        """
        let data = try await request([
            "api", "graphql", "-f", "query=\(query)",
            "-f", "id=\(pullRequest.id)", "-f", "reviewAuthor=\(viewer)"
        ])
        let payload = try GraphQLResponse<Payload>.decode(data)
        return Snapshot(viewer: payload.viewer.login,
                        pullRequest: payload.node?.pullRequest.toPullRequest(me: payload.viewer.login, machineAccounts: machineAccounts),
                        isOpen: payload.node?.state == "OPEN", isMerged: payload.node?.state == "MERGED")
    }
}
