import Foundation
import Testing

@testable import WorkBuddy

/// Malformed search qualifiers can silently return fewer results instead of errors, causing the app to omit PRs. Pin them here.
@Suite("Search query shape")
struct QueryShapeTests {
    @Test("Review queues are exact complements")
    func complementary() {
        // The queries must be complementary: excluding Dependabot from both loses items; including it in both duplicates results.
        #expect(ReviewQueue.baseSearchQuery.contains("-author:app/dependabot"))
        #expect(DependabotQueue.baseSearchQuery.contains("author:app/dependabot"))
        #expect(!DependabotQueue.baseSearchQuery.contains("-author:app/dependabot"))

        // Apart from the author filter, both queries must request the same data.
        let sinFiltro: (String) -> String = { query in
            query
                .replacingOccurrences(of: "-author:app/dependabot", with: "")
                .replacingOccurrences(of: "author:app/dependabot", with: "")
                .trimmingCharacters(in: .whitespaces)
        }
        #expect(sinFiltro(ReviewQueue.baseSearchQuery)
            == sinFiltro(DependabotQueue.baseSearchQuery))
    }

    @Test(
        "Queues use review-requested to include team requests",
        arguments: [ReviewQueue.baseSearchQuery, DependabotQueue.baseSearchQuery]
    )
    func includesTeamRequests(query: String) {
        // Measured: `review-requested:@me` returned 57 PRs versus 27 for `user-review-requested:@me`, which excludes team requests. The latter would lose more than half the queue; the former avoids maintaining a repository list manually.
        #expect(query.contains("review-requested:@me"))
        #expect(!query.contains("user-review-requested:@me"))
        #expect(query.contains("is:open"))
        #expect(query.contains("is:pr"))
        // Exclude archived repositories, whose PRs cannot be merged.
        #expect(query.contains("archived:false"))
    }

    @Test("Dependabot queries conflicts in pages of 25 and retains eight pages")
    func dependabotRequestsMergeability() async throws {
        let prs = try await DependabotQueue.fetch(viewer: Viewer(login: "me")) { arguments in
            let query = try #require(arguments.first { $0.hasPrefix("query=") })
            #expect(query.contains(DependabotQueue.baseSearchQuery))
            #expect(query.contains("mergeable"))
            #expect(!query.contains("mergeStateStatus"))
            #expect(query.contains("first: 25"))
            #expect(arguments.contains("reviewAuthor=me"))
            let page = arguments.first { $0.hasPrefix("cursor=") }
                .flatMap { Int($0.dropFirst("cursor=".count)) } ?? 0
            return try JSONSerialization.data(withJSONObject: ["data": [
                "viewer": ["login": "me"],
                "search": [
                    "pageInfo": ["hasNextPage": page < 7, "endCursor": String(page + 1)],
                    "nodes": [[
                        "id": "PR_\(page)", "number": page + 1, "title": "Dependency update",
                        "url": "https://github.com/org/repo/pull/\(page + 1)",
                        "repository": ["nameWithOwner": "org/repo"],
                        "author": ["login": "dependabot", "__typename": "Bot"],
                        "baseRefName": "main", "headRefName": "dependabot/update-\(page)",
                        "updatedAt": "2026-09-30T00:00:00Z", "mergeable": "MERGEABLE",
                        "commits": ["nodes": [["commit": ["statusCheckRollup": ["state": "SUCCESS"]]]]]
                    ]]
                ]
            ]])
        }
        #expect(prs.count == 8)
        #expect(prs.awaitingYourReview.count == 8)
    }

    @Test("Paginated queries declare and request the cursor")
    func pagination() {
        let query = PullRequestSearch.query(
            search: "is:open is:pr",
            fields: "id",
            pageSize: 25
        )
        // Without `hasNextPage` and `endCursor`, pagination silently stops at the first page.
        #expect(query.contains("query($cursor: String, $reviewAuthor: String!)"))
        #expect(query.contains("after: $cursor"))
        #expect(query.contains("hasNextPage"))
        #expect(query.contains("endCursor"))
        #expect(query.contains("first: 25"))
    }

    @Test("Merge queues request merge state")
    func mergeQueueRequestsMergeability() {
        // Merge queries also need the verdict on required conditions.
        #expect(PullRequestFields.withMergeState.contains("mergeable"))
        #expect(PullRequestFields.withMergeState.contains("mergeStateStatus"))
        #expect(!PullRequestFields.base.contains("mergeable"))
    }

    @Test("Personal decisions do not depend on a page of others' reviews")
    func personalReviewByAuthor() {
        #expect(PullRequestFields.base.contains(
            "myReview: reviews(author: $reviewAuthor, last: 1, states: [APPROVED, CHANGES_REQUESTED, DISMISSED])"
        ))
        #expect(MergeQueue.query(configuration: .empty).contains("query($reviewAuthor: String!)"))
    }

    @Test("Fix queries search own PRs without requiring review or successful CI")
    func fixQueueScope() throws {
        #expect(FixQueue.baseSearchQuery == "is:open is:pr author:@me archived:false")
        let configuration = try AppConfiguration(organizations: ["example-org"], machineAccountsText: "")
        #expect(FixQueue.searchQuery(configuration: configuration).hasSuffix("org:example-org"))
        #expect(FixQueue.searchQuery(configuration: .empty) == FixQueue.baseSearchQuery)
    }

    @Test("Configured organizations constrain every search")
    func organizationScope() throws {
        let configuration = try AppConfiguration(
            organizations: ["example-org"],
            machineAccountsText: ""
        )

        #expect(ReviewQueue.searchQuery(configuration: configuration)
            .hasSuffix("org:example-org"))
        #expect(DependabotQueue.searchQuery(configuration: configuration)
            .hasSuffix("org:example-org"))

        let mergeQuery = MergeQueue.query(configuration: configuration)
        #expect(mergeQuery.components(separatedBy: "org:example-org").count - 1 == 3)
    }

    @Test("Without configured organizations the scope remains global")
    func globalDefaultScope() {
        #expect(ReviewQueue.searchQuery(configuration: .empty)
            == ReviewQueue.baseSearchQuery)
        #expect(DependabotQueue.searchQuery(configuration: .empty)
            == DependabotQueue.baseSearchQuery)
        #expect(!MergeQueue.query(configuration: .empty).contains("org:"))
    }
}
