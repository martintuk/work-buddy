import Foundation

/// Your open PRs; domain policy selects failed CI. Paginate separately from
/// review requests and MergeQueue's candidate limit. Finding CI failures does
/// not require calculating mergeability.
enum FixQueue {
    static let baseSearchQuery = "is:open is:pr author:@me archived:false"

    static func searchQuery(configuration: AppConfiguration) -> String {
        configuration.scopedSearch(baseSearchQuery)
    }

    static func fetch(configuration: AppConfiguration = .empty, viewer: Viewer) async throws -> [PullRequest] {
        try await PullRequestSearch.fetch(
            viewer: viewer,
            search: searchQuery(configuration: configuration),
            pageSize: 25,
            maxPages: 20,
            machineAccounts: configuration.machineAccounts
        )
    }
}
