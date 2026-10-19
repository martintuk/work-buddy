import Foundation

/// Fetch human PRs requesting your review across repositories.
/// GraphQL avoids the smaller shared REST search budget and retrieves requests,
/// personal reviews, and CI together after resolving your login, without per-PR calls.
/// The original comparison used REST's 30 requests/minute versus GraphQL's
/// 5,000 points/hour budget.
enum ReviewQueue {
    /// Use pages of 25: nested connections returned 502 with first:100.
    /// Fifty also worked without mergeable, but the seven-PR human queue gained nothing.
    private static let pageSize = 25

    /// Cap pages so an enormous queue cannot keep the app loading indefinitely.
    private static let maxPages = 20

    /// Dependabot accounted for 50 of 57 measured PRs and has a separate query.
    /// Complementary author filters keep the human query small without gaps or overlap.
    /// Other automation accounts still arrive here and are classified by Author.isBot.
    static let baseSearchQuery =
        "is:open is:pr review-requested:@me archived:false -author:app/dependabot"

    static func searchQuery(configuration: AppConfiguration) -> String {
        configuration.scopedSearch(baseSearchQuery)
    }

    static func fetch(configuration: AppConfiguration = .empty, viewer: Viewer) async throws -> [PullRequest] {
        try await PullRequestSearch.fetch(
            viewer: viewer,
            search: searchQuery(configuration: configuration),
            pageSize: pageSize,
            maxPages: maxPages,
            machineAccounts: configuration.machineAccounts
        )
    }
}
