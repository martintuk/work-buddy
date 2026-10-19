import Foundation

/// Other authors' PRs with your mentions or participation. Reviewed-by also
/// covers code reviews; an outstanding review request is not required.
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
