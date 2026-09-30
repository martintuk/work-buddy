import Foundation
import Testing
@testable import WorkBuddy

@Suite("Recuperación de acciones")
@MainActor
struct PullRequestRecoveryTests {
    @Test("Una aprobación ya registrada aplica el efecto local sin repetir la escritura")
    func alreadyApproved() async throws {
        let pr = fixture(1)
        let batch = PullRequestBatch()
        batch.prepare([pr], viewer: "me")
        var reconciled = false
        let task = batch.start(.approve, read: { pr, viewer in
            var approved = pr
            approved.approvedByMe = true
            return .init(viewer: viewer, pullRequest: approved, isOpen: true)
        }, write: { _ in Issue.record("Ya está aprobada") }, isAllowed: { _ in true },
           didComplete: { _ in reconciled = true })
        await (try #require(task)).value
        #expect(reconciled && batch.skippedCount == 1 && batch.succeededCount == 0)
    }

    @Test("Sólo una escritura enviada con resultado ambiguo requiere verificación")
    func classifyFailures() throws {
        #expect(!GitHubActionRunner.needsVerification(GH.Failure.noAttempts, submitted: false))
        #expect(GitHubActionRunner.needsVerification(GH.Failure.noAttempts, submitted: true))
        for code in [403, 409, 422, 429, 502] {
            let response = try GitHubAPIResponse(Data("HTTP/2.0 \(code) Error\n\n{}".utf8))
            let error = GitHubAPIError(response: response, detail: "Error")
            #expect(GitHubActionRunner.needsVerification(error, submitted: true) == (code == 502))
        }
    }

    @Test("Limpiar actividad no permite que un lote repita una escritura incierta")
    func uncertainActionsStayBlocked() {
        let pr = fixture(1)
        let store = ReviewQueueStore.preview(reviews: [pr], merges: [])
        let id = store.activity.record(.approve, on: pr, status: .uncertain(LocalizedMessage("Connection lost")), viewer: "me")
        #expect(store.batchCandidates.isEmpty && store.availableWriteActions(for: pr).isEmpty)
        store.activity.clearCompleted()
        #expect(store.activity.entries.map(\.id) == [id])
        #expect(store.batchCandidates.isEmpty)
        #expect(store.activity.needsVerification(for: pr, viewer: "someone-else") == false)
    }

    @Test("Verificar una aprobación aplicada corrige la lista sin ejecutar otra escritura")
    func verifyApproval() async throws {
        let pr = fixture(1)
        let store = ReviewQueueStore.preview(reviews: [pr], merges: [])
        let id = store.activity.record(.approve, on: pr, status: .uncertain(LocalizedMessage("Connection lost")), viewer: "me")
        await store.verifyActivity(id) { pr, viewer, _ in
            var approved = pr
            approved.approvedByMe = true
            return .init(viewer: viewer, pullRequest: approved, isOpen: true)
        }
        let entry = try #require(store.activity.entries.first)
        #expect(entry.statusText == L10n.text(.prApproved))
        #expect(store.visibleSectionID(for: pr.id) == "automation")
        #expect(!store.canRetry(entry) && store.inFlightActions.isEmpty)
    }

    @Test("Verificar un merge aplicado retira el PR")
    func verifyMerge() async {
        let pr = fixture(1, mergeState: .clean)
        let store = ReviewQueueStore.preview(reviews: [pr], merges: [pr])
        let id = store.activity.record(.merge, on: pr, status: .uncertain(LocalizedMessage("Connection lost")), viewer: "me")
        await store.verifyActivity(id) { pr, viewer, _ in
            .init(viewer: viewer, pullRequest: pr, isOpen: false, isMerged: true)
        }
        #expect(store.currentPullRequest(id: pr.id) == nil)
        #expect(store.activity.entries.first?.status.isError == false)
    }

    @Test("Una acción ausente habilita el reintento explícito; otro error conserva la incertidumbre")
    func verifyMissingOrFailed() async throws {
        let pr = fixture(1)
        let store = ReviewQueueStore.preview(reviews: [pr], merges: [])
        let id = store.activity.record(.approve, on: pr, status: .uncertain(LocalizedMessage("Connection lost")), viewer: "me")
        await store.verifyActivity(id) { _, _, _ in throw GH.Failure.noAttempts }
        #expect(store.activity.entries.first?.status.needsVerification == true)
        await store.verifyActivity(id) { pr, viewer, _ in .init(viewer: viewer, pullRequest: pr, isOpen: true) }
        let entry = try #require(store.activity.entries.first)
        #expect(store.canRetry(entry) && !store.canVerify(entry))
        #expect(store.activity.entries.count == 1 && store.inFlightActions.isEmpty)
        #expect(!store.currentPullRequest(id: pr.id)!.approvedByMe)
    }

    @Test("Verificar nunca atribuye el resultado a otra cuenta ni a otro commit")
    func changedIdentity() async {
        let pr = fixture(1)
        let store = ReviewQueueStore.preview(reviews: [pr], merges: [])
        let id = store.activity.record(.approve, on: pr, status: .uncertain(LocalizedMessage("Connection lost")), viewer: "me")
        await store.verifyActivity(id) { pr, _, _ in .init(viewer: "other", pullRequest: pr, isOpen: true) }
        #expect(store.activity.entries.first?.status.needsVerification == true)
        await store.verifyActivity(id) { _, viewer, _ in .init(viewer: viewer, pullRequest: fixture(1, head: "new"), isOpen: true) }
        #expect(store.activity.entries.first?.status.isError == false)
        #expect(!store.currentPullRequest(id: pr.id)!.approvedByMe)
    }
}
