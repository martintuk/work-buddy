import Foundation

/// Fetch merge candidates using three searches in one aliased GraphQL request.
enum MergeQueue {
    /// No single search covers every merge candidate:
    /// - author:@me finds your own PRs.
    /// - reviewed-by:@me keeps approved PRs after approval removes the review request.
    ///   Adding it grew the measured section from one PR to five.
    /// - review-requested:@me review:approved finds PRs approved by others that still request you.
    /// Only the last query uses review:approved: it reduced 56 candidates to two in
    /// the original environment without losing mergeable PRs. See docs/assumptions.md.
    /// The reviewed-by set was only 12 without the filter versus seven with it; adding
    /// that assumption there offered little benefit.
    static func query(configuration: AppConfiguration) -> String {
        let authored = configuration.scopedSearch("is:open is:pr author:@me archived:false")
        let reviewed = configuration.scopedSearch("is:open is:pr reviewed-by:@me archived:false")
        let reviewing = configuration.scopedSearch(
            "is:open is:pr review-requested:@me review:approved archived:false"
        )
        return """
    query($reviewAuthor: String!) {
      viewer { login }
      authored: search(
        query: "\(authored)"
        type: ISSUE
        first: 30
      ) {
        nodes { ... on PullRequest { \(PullRequestFields.withMergeState) } }
      }
      reviewed: search(
        query: "\(reviewed)"
        type: ISSUE
        first: 30
      ) {
        nodes { ... on PullRequest { \(PullRequestFields.withMergeState) } }
      }
      reviewing: search(
        query: "\(reviewing)"
        type: ISSUE
        first: 30
      ) {
        nodes { ... on PullRequest { \(PullRequestFields.withMergeState) } }
      }
    }
    """
    }

    struct Payload: Decodable {
        let viewer: Viewer
        let authored: SearchPage
        let reviewed: SearchPage
        let reviewing: SearchPage
    }

    /// Return deduplicated candidates; readyToMerge applies merge eligibility.
    static func fetch(configuration: AppConfiguration = .empty, viewer: Viewer) async throws -> [PullRequest] {
        let query = query(configuration: configuration)
        let data = try await GH.runRetrying([
            "api", "graphql", "-f", "query=\(query)", "-f", "reviewAuthor=\(viewer.login)"
        ])
        let payload = try GraphQLResponse<Payload>.decode(data)
        let me = payload.viewer.login

        let candidates = (payload.authored.nodes + payload.reviewed.nodes + payload.reviewing.nodes)
            .compactMap {
                $0?.toPullRequest(me: me, machineAccounts: configuration.machineAccounts)
            }

        // Searches overlap: a reviewed PR that still requests you can appear in two sets.
        var seen: Set<String> = []
        return candidates.filter { seen.insert($0.id).inserted }
    }
}
