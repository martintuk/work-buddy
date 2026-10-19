import Foundation

/// Load Dependabot PRs requesting your review.
///
/// review-requested:@me includes team requests: measurements found 50 Dependabot
/// PRs versus 21 using the direct-only user-review-requested:@me filter.
/// CODEOWNERS and team membership therefore supply the repository scope, avoiding
/// a second manual allowlist that drifts as teams and repositories change.
enum DependabotQueue {
    /// Confirming no conflicts requires mergeable. Pages of 50 returned 502;
    /// 25 worked. See docs/assumptions.md.
    private static let pageSize = 25

    /// Retain the previous 200-PR capacity after reducing page size.
    private static let maxPages = 8

    /// Exact complement of ReviewQueue.searchQuery.
    static let baseSearchQuery =
        "is:open is:pr review-requested:@me archived:false author:app/dependabot"

    static func searchQuery(configuration: AppConfiguration) -> String {
        configuration.scopedSearch(baseSearchQuery)
    }

    static func fetch(
        configuration: AppConfiguration = .empty, viewer: Viewer,
        request: @Sendable ([String]) async throws -> Data = { try await GH.runRetrying($0) }
    ) async throws -> [PullRequest] {
        try await PullRequestSearch.fetch(
            viewer: viewer,
            search: searchQuery(configuration: configuration),
            fields: PullRequestFields.withMergeability,
            pageSize: pageSize,
            maxPages: maxPages,
            machineAccounts: configuration.machineAccounts,
            request: request
        )
    }
}
