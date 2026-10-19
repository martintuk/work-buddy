import Foundation
import Testing
@testable import WorkBuddy

@Suite("Action recovery")
@MainActor
struct PullRequestRecoveryTests {
    @Test("Existing approvals apply local effects without repeating writes")
    func alreadyApproved() async throws {
        let pr = fixture(1)
        let batch = PullRequestBatch()
        batch.prepare([pr], viewer: "me")
        var reconciled = false
        let task = batch.start(.approve, read: { pr, viewer in
            var approved = pr
            approved.approvedByMe = true
            return .init(viewer: viewer, pullRequest: approved, isOpen: true)
        }, write: { _ in Issue.record("Already approved") }, isAllowed: { _ in true },
           didComplete: { _ in reconciled = true })
        await (try #require(task)).value
        #expect(reconciled && batch.skippedCount == 1 && batch.succeededCount == 0)
    }

    @Test("Only sent writes with ambiguous outcomes require verification")
    func classifyFailures() throws {
        #expect(!GitHubActionRunner.needsVerification(GH.Failure.noAttempts, submitted: false))
        #expect(GitHubActionRunner.needsVerification(GH.Failure.noAttempts, submitted: true))
        for code in [403, 409, 422, 429, 502] {
            let response = try GitHubAPIResponse(Data("HTTP/2.0 \(code) Error\n\n{}".utf8))
            let error = GitHubAPIError(response: response, detail: "Error")
            #expect(GitHubActionRunner.needsVerification(error, submitted: true) == (code == 502))
        }
    }

    @Test("Uncertain writes prevent batches from repeating actions")
    func uncertainActionsStayBlocked() {
        let pr = fixture(1)
        let store = ReviewQueueStore.preview(reviews: [pr], merges: [])
        let id = store.activity.record(.approve, on: pr, status: .uncertain(LocalizedMessage("Connection lost")), viewer: "me")
        #expect(store.batchCandidates.isEmpty && store.availableWriteActions(for: pr).isEmpty)
        #expect(store.activity.entries.map(\.id) == [id])
        #expect(store.batchCandidates.isEmpty)
        #expect(store.activity.needsVerification(for: pr, viewer: "someone-else") == false)
    }

    @Test("Menus offer verification only for uncertain outcomes of the same account and commit")
    func verificationFromPullRequest() {
        let pr = fixture(1)
        let store = ReviewQueueStore.preview(reviews: [pr], merges: [])
        #expect(store.actionToVerify(for: pr) == nil)
        store.activity.record(.approve, on: pr, status: .uncertain(LocalizedMessage("Connection lost")), viewer: "other")
        #expect(store.actionToVerify(for: pr) == nil)
        let id = store.activity.record(.approve, on: pr, status: .uncertain(LocalizedMessage("Connection lost")), viewer: "me")
        #expect(store.actionToVerify(for: pr)?.id == id)
        #expect(store.actionToVerify(for: fixture(1, head: "new")) == nil)
        #expect(store.actionToVerify(for: fixture(2)) == nil)
        // Later activity on the same PR must not hide its pending outcome.
        store.activity.record(.open, on: pr)
        #expect(store.actionToVerify(for: pr)?.id == id)
    }

    @Test("Verifying applied approvals corrects the list without another write")
    func verifyApproval() async throws {
        let pr = fixture(1)
        let store = ReviewQueueStore.preview(reviews: [pr], merges: [])
        let id = store.activity.record(.approve, on: pr, status: .uncertain(LocalizedMessage("Connection lost")), viewer: "me")
        await store.verifyAction(id) { pr, viewer, _ in
            var approved = pr
            approved.approvedByMe = true
            return .init(viewer: viewer, pullRequest: approved, isOpen: true)
        }
        let entry = try #require(store.activity.entries.first)
        #expect(entry.statusText == L10n.text(.prApproved))
        #expect(store.automation.contains { $0.id == pr.id })
        #expect(store.actionToVerify(for: pr) == nil && store.inFlightActions.isEmpty)
    }

    @Test("Verifying applied merges removes the PR")
    func verifyMerge() async {
        let pr = fixture(1, mergeState: .clean)
        let store = ReviewQueueStore.preview(reviews: [pr], merges: [pr])
        let id = store.activity.record(.merge, on: pr, status: .uncertain(LocalizedMessage("Connection lost")), viewer: "me")
        await store.verifyAction(id) { pr, viewer, _ in
            .init(viewer: viewer, pullRequest: pr, isOpen: false, isMerged: true)
        }
        #expect(store.currentPullRequest(id: pr.id) == nil)
        #expect(store.activity.entries.first?.status.isError == false)
    }

    @Test("Absent actions allow explicit retry; further errors preserve uncertainty")
    func verifyMissingOrFailed() async throws {
        let pr = fixture(1)
        let store = ReviewQueueStore.preview(reviews: [pr], merges: [])
        let id = store.activity.record(.approve, on: pr, status: .uncertain(LocalizedMessage("Connection lost")), viewer: "me")
        await store.verifyAction(id) { _, _, _ in throw GH.Failure.noAttempts }
        #expect(store.activity.entries.first?.status.needsVerification == true)
        #expect(store.actionToVerify(for: pr)?.id == id && store.availableWriteActions(for: pr).isEmpty)
        await store.verifyAction(id) { pr, viewer, _ in .init(viewer: viewer, pullRequest: pr, isOpen: true) }
        #expect(store.availableWriteActions(for: pr).contains(.approve) && store.actionToVerify(for: pr) == nil)
        #expect(store.activity.entries.count == 1 && store.inFlightActions.isEmpty)
        #expect(!store.currentPullRequest(id: pr.id)!.approvedByMe)
    }

    @Test("Verification never attributes outcomes to another account or commit")
    func changedIdentity() async {
        let pr = fixture(1)
        let store = ReviewQueueStore.preview(reviews: [pr], merges: [])
        let id = store.activity.record(.approve, on: pr, status: .uncertain(LocalizedMessage("Connection lost")), viewer: "me")
        await store.verifyAction(id) { pr, _, _ in .init(viewer: "other", pullRequest: pr, isOpen: true) }
        #expect(store.activity.entries.first?.status.needsVerification == true)
        await store.verifyAction(id) { _, viewer, _ in .init(viewer: viewer, pullRequest: fixture(1, head: "new"), isOpen: true) }
        #expect(store.activity.entries.first?.status.isError == false)
        #expect(!store.currentPullRequest(id: pr.id)!.approvedByMe)
    }
}
