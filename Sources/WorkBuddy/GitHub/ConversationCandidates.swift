import Foundation

/// PRs ajenos donde hubo una mención o participación propia. Reviewed-by cubre
/// también las reviews sobre código; no exigimos que sigan pidiendo tu review.
enum ConversationCandidates {
    static let searches = [
        "is:open is:pr -author:@me involves:@me archived:false",
        "is:open is:pr -author:@me reviewed-by:@me archived:false"
    ]

    static func fetch(configuration: AppConfiguration, viewer: Viewer) async throws -> [PullRequest] {
        async let involved = PullRequestSearch.fetch(
            viewer: viewer,
            search: configuration.scopedSearch(searches[0]), pageSize: 25, maxPages: 40,
            machineAccounts: configuration.machineAccounts
        )
        async let reviewed = PullRequestSearch.fetch(
            viewer: viewer,
            search: configuration.scopedSearch(searches[1]), pageSize: 25, maxPages: 40,
            machineAccounts: configuration.machineAccounts
        )
        let candidates = try await involved + reviewed
        var seen = Set<String>()
        return candidates.filter { !$0.authoredByMe && seen.insert($0.id).inserted }
    }
}
