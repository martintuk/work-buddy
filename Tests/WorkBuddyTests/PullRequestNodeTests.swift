import Foundation
import Testing

@testable import WorkBuddy

@Suite("Aprobación personal de GitHub")
struct PullRequestNodeTests {
    @Test("Un approval propio se detecta aunque no esté en los primeros reviewers")
    func aprobacionFueraDeLaPagina() throws {
        let pr = try decode(
            personalState: "APPROVED",
            latestReviews: (1...10).map { review(author: "other-\($0)", state: "APPROVED") }
        )
        #expect(pr.approvedByMe)
        #expect(pr.bucket() == nil)
        #expect([pr].reviewSections.isEmpty)
        #expect([pr].awaitingYourReview.isEmpty)
    }

    @Test("Comentar después de aprobar no invalida la aprobación")
    func comentarioPosterior() throws {
        let pr = try decode(
            personalState: "APPROVED",
            latestReviews: [review(author: "me", state: "COMMENTED")]
        )
        #expect(pr.approvedByMe)
        #expect(pr.bucket() == nil)
    }

    @Test("Un approval descartado o reemplazado por cambios no oculta el PR",
          arguments: ["DISMISSED", "CHANGES_REQUESTED", "COMMENTED", "PENDING", "UNKNOWN"])
    func decisionSinAprobacion(state: String) throws {
        let pr = try decode(
            personalState: state,
            latestReviews: [review(author: "me", state: "APPROVED")]
        )
        #expect(!pr.approvedByMe)
        #expect(pr.bucket() == .needsReview)
        #expect([pr].awaitingYourReview.map(\.id) == [pr.id])
    }

    @Test("Sin decisión personal no se usa la aprobación de otro")
    func sinReviewPersonal() throws {
        let pr = try decode(personalState: nil, latestReviews: [review(author: "other", state: "APPROVED")])
        #expect(!pr.approvedByMe)
        #expect(pr.bucket() == .needsReview)
    }

    @Test("La aprobación debe pertenecer a la cuenta activa")
    func identidadDelReviewer() throws {
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
