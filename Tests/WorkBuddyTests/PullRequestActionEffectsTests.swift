import Testing
@testable import WorkBuddy

@Suite("Resultados visibles de acciones")
struct PullRequestActionEffectsTests {
    @Test("Cambiar la cuenta conserva revisiones crecientes para las lecturas en curso")
    func resetRevision() {
        var effects = PullRequestActionEffects()
        effects.record(.approve, on: fixture(1))
        let started = effects.revision
        effects.reset()
        effects.record(.merge, on: fixture(2))
        #expect(effects.applying(to: [fixture(2)], readRevision: started).isEmpty)
        #expect(!effects.applying(to: [fixture(1)], readRevision: started)[0].approvedByMe)
    }

    @Test("Lecturas anteriores no reviven merges ni revierten una aprobación")
    func staleResults() {
        var effects = PullRequestActionEffects()
        let approved = fixture(1), merged = fixture(2)
        let started = effects.revision
        effects.record(.approve, on: approved)
        effects.record(.rebase, on: approved)
        effects.record(.merge, on: merged)
        let projected = effects.applying(to: [approved, merged, fixture(3)], readRevision: started)
        #expect(projected.map(\.id) == [approved.id, fixture(3).id])
        #expect(projected[0].approvedByMe && !projected[0].canApprove)
        #expect(!projected[0].canMerge)
        // Una fuente parcial puede publicar después de otra: conserva la protección.
        #expect(effects.applying(to: [merged], readRevision: started).isEmpty)
    }

    @Test("Una aprobación no se extiende a otro commit ni tapa una decisión posterior")
    func laterDecisions() {
        var effects = PullRequestActionEffects()
        let original = fixture(1)
        effects.record(.approve, on: original)
        let newHead = fixture(1, head: "new")
        #expect(!effects.applying(to: [newHead], readRevision: 0)[0].approvedByMe)
        #expect(!effects.applying(to: [original], readRevision: effects.revision)[0].approvedByMe)
        let started = effects.revision
        effects.record(.merge, on: fixture(2))
        effects.finishRefresh(startedAt: started)
        #expect(effects.applying(to: [fixture(2)], readRevision: started).isEmpty)
    }

    @Test("Un rebase no recupera el atraso calculado antes de terminar")
    func behindCounts() {
        var effects = PullRequestActionEffects()
        effects.record(.rebase, on: fixture(1))
        #expect(effects.applying(to: [fixture(1).id: 5], readRevision: 0).isEmpty)
        #expect(effects.applying(to: [fixture(1).id: 2], readRevision: 1)[fixture(1).id] == 2)
    }

    @Test("Aprobar conserva el PR que espera otra aprobación; mergear lo retira")
    @MainActor
    func storeTransitions() {
        let pr = fixture(1)
        let store = ReviewQueueStore.preview(reviews: [pr], merges: [pr])
        store.applyCompletedAction(.approve, on: pr)
        #expect(store.reviewSections.isEmpty)
        #expect(store.automation.map(\.id) == [pr.id])
        #expect(store.currentPullRequest(id: pr.id)?.approvedByMe == true)
        #expect(store.readyToMerge.isEmpty)
        store.applyCompletedAction(.merge, on: pr)
        #expect(store.automation.isEmpty && store.currentPullRequest(id: pr.id) == nil)
    }
}
