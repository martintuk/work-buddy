import Foundation
import Testing

@testable import WorkBuddy

@Suite("GitHub personal approval")
struct PullRequestNodeTests {
    @Test("Detect personal approval beyond the first reviewers")
    func approvalBeyondPage() throws {
        let pr = try decode(
            personalState: "APPROVED",
            latestReviews: (1...10).map { review(author: "other-\($0)", state: "APPROVED") }
        )
        #expect(pr.approvedByMe)
        #expect(pr.bucket() == nil)
        #expect([pr].reviewSections.isEmpty)
        #expect([pr].awaitingYourReview.isEmpty)
    }

    @Test("Comments after approval do not invalidate it")
    func laterComment() throws {
        let pr = try decode(
            personalState: "APPROVED",
            latestReviews: [review(author: "me", state: "COMMENTED")]
        )
        #expect(pr.approvedByMe)
        #expect(pr.bucket() == nil)
    }

    @Test("Dismissed approvals or requested changes do not hide PRs",
          arguments: ["DISMISSED", "CHANGES_REQUESTED", "COMMENTED", "PENDING", "UNKNOWN"])
    func decisionWithoutApproval(state: String) throws {
        let pr = try decode(
            personalState: state,
            latestReviews: [review(author: "me", state: "APPROVED")]
        )
        #expect(!pr.approvedByMe)
        #expect(pr.bucket() == .needsReview)
        #expect([pr].awaitingYourReview.map(\.id) == [pr.id])
    }

    @Test("Other approvals cannot replace a missing personal decision")
    func noPersonalReview() throws {
        let pr = try decode(personalState: nil, latestReviews: [review(author: "other", state: "APPROVED")])
        #expect(!pr.approvedByMe)
        #expect(pr.bucket() == .needsReview)
    }

    @Test("Approval must belong to the active account")
    func reviewerIdentity() throws {
        #expect(try decode(personalState: "APPROVED", personalAuthor: "ME").approvedByMe)
        #expect(try !decode(personalState: "APPROVED", personalAuthor: "other").approvedByMe)
    }

    private func review(author: String, state: String) -> [String: Any] {
        ["author": ["login": author], "state": state]
    }

    private func decode(
        personalState: String?,
        personalAuthor: String = "me",
        latestReviews: [[String: Any]] = []
    ) throws -> PullRequest {
        let personalReviews = personalState.map { [review(author: personalAuthor, state: $0)] } ?? []
        let fixture: [String: Any] = [
            "id": "PR_1", "number": 1, "title": "Un cambio",
            "url": "https://github.com/org/repo/pull/1",
            "repository": ["nameWithOwner": "org/repo"],
            "baseRefName": "main", "headRefName": "feature",
            "updatedAt": "2026-09-04T00:00:00Z",
            "reviewDecision": "REVIEW_REQUIRED",
            "author": ["login": "alice", "__typename": "User"],
            "latestReviews": ["nodes": latestReviews],
            "myReview": ["nodes": personalReviews]
        ]
        let data = try JSONSerialization.data(withJSONObject: fixture)
        let node = try JSONDecoder.github.decode(PullRequestNode.self, from: data)
        return try #require(node.toPullRequest(me: "me"))
    }
}
