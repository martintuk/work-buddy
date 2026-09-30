import AppKit
import SwiftUI
import Testing
@testable import WorkBuddy

@Suite("Acciones de PRs en lote")
@MainActor
struct PullRequestBatchTests {
    @Test("Filtra elegibilidad de aprobación y deduplica sin limitarse a Dependabot")
    func selection() {
        let ready = pr(1)
        var noCommit = pr(2)
        noCommit.headRefOID = nil
        let candidates = [ready, ready, noCommit, pr(3, checks: .pending), pr(4, mergeable: .conflicting),
                          pr(5, author: "renovate[bot]"), pr(6, draft: true), pr(7, approved: true),
                          pr(8, decision: .approved), pr(9, mergeable: .unknown)]
        let batch = PullRequestBatch()
        batch.prepare(candidates, viewer: "me")
        #expect(batch.candidates.map(\.id) == [ready.id, "PR_5"])
        #expect(batch.selectedIDs == [ready.id, "PR_5"])
        batch.toggle("missing")
        #expect(batch.selectedIDs == [ready.id, "PR_5"])
        batch.toggle(ready.id)
        batch.toggle("PR_5")
        #expect(batch.selectedIDs.isEmpty)
        let empty = batch.start(.approve, read: { _, _ in fatalError() }, write: { _ in fatalError() }, isAllowed: { _ in true })
        #expect(empty == nil)
        batch.toggleAllForTesting()
        #expect(batch.selectedIDs == [ready.id, "PR_5"])
        batch.toggleAllForTesting()
        #expect(batch.selectedIDs.isEmpty)
    }

    @Test("Revalida el commit, la cuenta, CI, draft y aprobación antes de escribir")
    func validation() {
        let original = pr(1)
        func reason(_ current: PullRequest?, open: Bool = true, viewer: String = "me") -> PullRequestActionSkipReason? {
            PullRequestBatchAction.approve.skipReason(for: original, snapshot: .init(viewer: viewer, pullRequest: current, isOpen: open), viewer: "me", batch: true)
        }
        #expect(reason(original) == nil)
        #expect(reason(original, viewer: "ME") == nil)
        #expect(reason(original, viewer: "other") == .accountChanged)
        #expect(reason(original, open: false) == .closed)
        #expect(reason(nil) == .closed)
        var changed = original
        changed.headRefOID = "different-commit"
        #expect(reason(changed) == .changed)
        changed.headRefOID = nil
        #expect(reason(changed) == .changed)
        #expect(reason(pr(1, approved: true)) == .alreadyApproved)
        for check in [CheckState.pending, .failure, .unknown, .expected, .error] {
            #expect(reason(pr(1, checks: check)) == .notReady)
        }
        #expect(reason(pr(1, draft: true)) == .notReady)
        #expect(reason(pr(1, mergeable: .unknown)) == .notReady)
        #expect(reason(pr(1, mergeable: .conflicting)) == .notReady)
        #expect(reason(pr(1, decision: .approved)) == .notReady)
        #expect(reason(pr(1, author: "renovate[bot]")) == nil)
    }

    @Test("El refresh muestra recién llegados sin seleccionarlos y retira selecciones desactualizadas")
    func reconciliation() {
        let batch = PullRequestBatch()
        batch.prepare([pr(1), pr(2), pr(3), pr(4)], viewer: "me")
        batch.toggle("PR_2")
        var changed = pr(3)
        changed.headRefOID = "new"
        batch.reconcile([pr(1), pr(2), changed, pr(4, checks: .pending), pr(5)])
        #expect(batch.candidates.map(\.id) == ["PR_1", "PR_2", "PR_3", "PR_5"])
        #expect(batch.selectedIDs == ["PR_1"])
        batch.reconcile([])
        #expect(batch.candidates.isEmpty && batch.selectedIDs.isEmpty)
    }

    @Test("Resultados parciales: nunca reintenta una aprobación incierta y continúa el lote")
    func partialResults() async throws {
        let batch = PullRequestBatch()
        batch.prepare([pr(1), pr(2), pr(3), pr(4)], viewer: "me")
        batch.toggle("PR_4")
        let calls = BatchCalls()
        var approved: [String] = []
        var finished = 0
        let started = batch.start(.approve, read: { pr, viewer in
            var current = pr
            if pr.number == 2 { current.headRefOID = "new" }
            return .init(viewer: viewer, pullRequest: current, isOpen: true)
        }, write: { pr in
            await calls.record(pr.id)
            if pr.number == 3 { throw GH.Failure.commandFailed(exitCode: 1, stderr: "HTTP 502") }
        }, isAllowed: { _ in true }, didComplete: { approved.append($0.id) }, didFinish: { finished += 1 })
        let task = try #require(started)
        #expect(batch.isRunning)
        let duplicate = batch.start(.approve, read: { _, _ in fatalError() }, write: { _ in fatalError() }, isAllowed: { _ in true })
        #expect(duplicate == nil)
        batch.toggleAllForTesting()
        #expect(batch.selectedIDs.isEmpty)
        await task.value
        #expect(!batch.isRunning)
        #expect(batch.entries.count == 3)
        #expect(batch.completedCount == 3)
        #expect(batch.succeededCount == 1 && batch.skippedCount == 1 && batch.failedCount == 1)
        #expect(await calls.ids == ["PR_1", "PR_3"])
        #expect(approved == ["PR_1"] && finished == 1)
    }

    @Test("Un cambio de alcance durante la lectura omite la escritura")
    func scopeDuringRead() async throws {
        let batch = PullRequestBatch()
        batch.prepare([pr(1)], viewer: "me")
        let gate = BatchGate()
        var allowed = true
        let started = batch.start(.approve, read: { pr, viewer in
            await gate.enter()
            return .init(viewer: viewer, pullRequest: pr, isOpen: true)
        }, write: { _ in Issue.record("No debe escribir después de cambiar el alcance") }, isAllowed: { _ in allowed })
        let task = try #require(started)
        await gate.waitUntilEntered()
        allowed = false
        await gate.release()
        await task.value
        #expect(batch.skippedCount == 1)
        if case .skipped(.scopeChanged) = batch.entries[0].status {} else { Issue.record("Debe indicar cambio de alcance") }
    }

    @Test("Detener durante la lectura no aprueba; durante la escritura termina el PR actual", arguments: [false, true])
    func stop(duringWrite: Bool) async throws {
        let batch = PullRequestBatch()
        batch.prepare([pr(1), pr(2)], viewer: "me")
        let gate = BatchGate()
        let writes = BatchCalls()
        let started = batch.start(.approve, read: { pr, viewer in
            if !duringWrite { await gate.enter() }
            return .init(viewer: viewer, pullRequest: pr, isOpen: true)
        }, write: { pr in
            await writes.record(pr.id)
            if duringWrite { await gate.enter() }
        }, isAllowed: { _ in true })
        let task = try #require(started)
        await gate.waitUntilEntered()
        batch.exit()
        batch.prepare([pr(9)], viewer: "other")
        batch.reconcile([])
        #expect(batch.isSelecting)
        #expect(batch.viewer == "me" && batch.entries.map(\.id) == ["PR_1", "PR_2"])
        batch.stop()
        await gate.release()
        await task.value
        #expect(await writes.ids == (duringWrite ? ["PR_1"] : []))
        #expect(batch.succeededCount == (duringWrite ? 1 : 0))
        #expect(batch.skippedCount == (duringWrite ? 1 : 2))
    }

    @Test("Un cambio de cuenta detiene los PRs restantes")
    func accountChange() async throws {
        let batch = PullRequestBatch()
        batch.prepare([pr(1), pr(2)], viewer: "me")
        let calls = BatchCalls()
        let started = batch.start(.approve, read: { pr, _ in
            await calls.record(pr.id)
            return .init(viewer: "other", pullRequest: pr, isOpen: true)
        }, write: { _ in Issue.record("No debe aprobar con otra cuenta") }, isAllowed: { _ in true })
        let task = try #require(started)
        await task.value
        #expect(await calls.ids == ["PR_1"])
        #expect(batch.skippedCount == 2)
        if case .skipped(.accountChanged) = batch.entries[0].status {} else { Issue.record("Cuenta cambiada") }
    }

    @Test("Consulta GitHub por ID y conserva el commit y la aprobación personal")
    func freshQuery() async throws {
        let snapshot = try await PullRequestActionCheck.fetch(pr(1), viewer: "me") { arguments in
            let query = try #require(arguments.first { $0.hasPrefix("query=") })
            #expect(query.contains("node(id: $id)"))
            #expect(query.contains("state") && query.contains("headRefOid") && query.contains("mergeable"))
            #expect(arguments.contains("id=PR_1") && arguments.contains("reviewAuthor=me"))
            return Data(#"{"data":{"viewer":{"login":"me"},"node":{"id":"PR_1","number":1,"title":"Update","url":"https://github.com/org/api/pull/1","repository":{"nameWithOwner":"org/api"},"author":{"login":"dependabot","__typename":"Bot"},"state":"OPEN","baseRefName":"main","headRefName":"update","headRefOid":"commit-1","updatedAt":"2026-09-30T00:00:00Z","mergeable":"MERGEABLE","isDraft":false,"myReview":{"nodes":[{"author":{"login":"me"},"state":"APPROVED"}]},"commits":{"nodes":[{"commit":{"statusCheckRollup":{"state":"SUCCESS"}}}]}}}}"#.utf8)
        }
        #expect(snapshot.isOpen)
        #expect(snapshot.pullRequest?.headRefOID == "commit-1")
        #expect(snapshot.pullRequest?.approvedByMe == true)
        #expect(PullRequestBatchAction.approve.skipReason(for: pr(1), snapshot: snapshot, viewer: "me", batch: true) == .alreadyApproved)
        let args = GitHubWrite.approveCommit(repository: "org/api", number: 1, commitID: "commit-1").arguments
        #expect(args == ["api", "repos/org/api/pulls/1/reviews", "--method", "POST", "-f", "event=APPROVE", "-f", "commit_id=commit-1"])
    }

    @Test("Una lectura fallida conserva el error y no escribe")
    func readFailure() async throws {
        let batch = PullRequestBatch()
        batch.prepare([pr(1)], viewer: "me")
        let started = batch.start(.approve, read: { _, _ in throw GH.Failure.noAttempts },
                                  write: { _ in Issue.record("No debe escribir sin lectura válida") }, isAllowed: { _ in true })
        let task = try #require(started)
        await task.value
        #expect(batch.failedCount == 1 && batch.succeededCount == 0)
    }

    @Test("Espacia las aprobaciones un segundo y revalida después de esperar")
    func approvalSpacing() async throws {
        let clock = ApprovalClock()
        let batch = PullRequestBatch(runner: clock.coordinator())
        batch.prepare([pr(1), pr(2)], viewer: "me")
        let reads = ApprovalCalls()
        let writes = ApprovalCalls()
        let started = batch.start(.approve, read: { pr, viewer in
            await reads.record(pr.id, at: clock.date)
            return .init(viewer: viewer, pullRequest: pr, isOpen: true)
        }, write: { pr in await writes.record(pr.id, at: clock.date) }, isAllowed: { _ in true })
        await (try #require(started)).value
        #expect(batch.succeededCount == 2)
        #expect(await writes.times == [0, 1])
        #expect(await reads.times == [0, 1])
    }

    @Test("Pausa el lote ante 429 o 422 por velocidad y revalida antes de reintentar", arguments: [429, 422])
    func rateLimitRecovery(status: Int) async throws {
        let clock = ApprovalClock()
        let batch = PullRequestBatch(runner: clock.coordinator())
        batch.prepare([pr(1), pr(2)], viewer: "me")
        let reads = ApprovalCalls()
        let writes = ApprovalCalls()
        let limit = try rateLimit(headers: status == 429 ? "Retry-After: 5" : "", status: status)
        let delay: TimeInterval = status == 429 ? 5 : 60
        let started = batch.start(.approve, read: { pr, viewer in
            await reads.record(pr.id, at: clock.date)
            return .init(viewer: viewer, pullRequest: pr, isOpen: true)
        }, write: { pr in
            await writes.record(pr.id, at: clock.date)
            if await writes.ids.count == 1 { throw limit }
        }, isAllowed: { _ in true })
        await (try #require(started)).value
        #expect(batch.succeededCount == 2 && batch.failedCount == 0)
        #expect(await writes.ids == ["PR_1", "PR_1", "PR_2"])
        #expect(await writes.times == [0, delay, delay + 1])
        #expect(await reads.times == [0, delay, delay + 1])
    }

    @Test("No duplica una aprobación que aparece al revalidar")
    func approvalAlreadyRegistered() async throws {
        let clock = ApprovalClock()
        let batch = PullRequestBatch(runner: clock.coordinator())
        batch.prepare([pr(1)], viewer: "me")
        let reads = BatchCalls()
        let writes = BatchCalls()
        let limit = try rateLimit(headers: "Retry-After: 2")
        let alreadyApproved = pr(1, approved: true)
        let started = batch.start(.approve, read: { pr, viewer in
            await reads.record(pr.id)
            let current = await reads.ids.count > 1 ? alreadyApproved : pr
            return .init(viewer: viewer, pullRequest: current, isOpen: true)
        }, write: { pr in await writes.record(pr.id); throw limit }, isAllowed: { _ in true })
        await (try #require(started)).value
        #expect(await writes.ids.count == 1)
        #expect(batch.succeededCount == 1 && batch.skippedCount == 0)
    }

    @Test("Omite el PR si cambió su commit o CI durante la espera", arguments: [false, true])
    func changedDuringCooldown(changeCommit: Bool) async throws {
        let clock = ApprovalClock()
        let batch = PullRequestBatch(runner: clock.coordinator())
        batch.prepare([pr(1)], viewer: "me")
        let reads = BatchCalls()
        let writes = BatchCalls()
        let limit = try rateLimit(headers: "Retry-After: 2")
        var updated = pr(1, checks: changeCommit ? .success : .pending)
        if changeCommit { updated.headRefOID = "new" }
        let changed = updated
        let started = batch.start(.approve, read: { pr, viewer in
            await reads.record(pr.id)
            let current = await reads.ids.count > 1 ? changed : pr
            return .init(viewer: viewer, pullRequest: current, isOpen: true)
        }, write: { pr in await writes.record(pr.id); throw limit }, isAllowed: { _ in true })
        await (try #require(started)).value
        #expect(await writes.ids.count == 1)
        #expect(batch.skippedCount == 1 && batch.succeededCount == 0)
        if case .skipped(let reason) = batch.entries[0].status {
            #expect(reason == (changeCommit ? .changed : .notReady))
        } else { Issue.record("Debe omitirlo después de la revalidación") }
    }

    @Test("Limita a tres intentos, omite el resto y conserva el cooldown para otra aprobación")
    func persistentRateLimit() async throws {
        let clock = ApprovalClock()
        let coordinator = clock.coordinator()
        let batch = PullRequestBatch(runner: coordinator)
        batch.prepare([pr(1), pr(2)], viewer: "me")
        let writes = ApprovalCalls()
        let limit = try rateLimit()
        let read: @Sendable (PullRequest, String) async throws -> PullRequestActionCheck.Snapshot = { pr, viewer in
            .init(viewer: viewer, pullRequest: pr, isOpen: true)
        }
        let started = batch.start(.approve, read: read, write: { pr in
            await writes.record(pr.id, at: clock.date)
            throw limit
        }, isAllowed: { _ in true })
        await (try #require(started)).value
        #expect(await writes.ids == ["PR_1", "PR_1", "PR_1"])
        #expect(await writes.times == [0, 60, 180])
        #expect(batch.failedCount == 1 && batch.skippedCount == 1)
        if case .skipped(.rateLimited) = batch.entries[1].status {} else { Issue.record("Debe detener el resto del lote") }
        _ = try await coordinator.perform(pr(3), viewer: "me", batch: false, read: read,
                                          write: { pr in await writes.record(pr.id, at: clock.date) })
        #expect(await writes.times == [0, 60, 180, 420])
    }

    @Test("Detener o cambiar alcance durante el cooldown impide nuevos intentos", arguments: [false, true])
    func stopDuringCooldown(scopeChange: Bool) async throws {
        let clock = ApprovalClock()
        let gate = BatchGate()
        let coordinator = GitHubActionRunner(now: { clock.date }, sleep: { seconds in
            await gate.enter()
            clock.advance(seconds)
        })
        let batch = PullRequestBatch(runner: coordinator)
        batch.prepare([pr(1), pr(2)], viewer: "me")
        var allowed = true
        let writes = BatchCalls()
        let limit = try rateLimit(headers: "Retry-After: 60")
        let started = batch.start(.approve, read: { pr, viewer in .init(viewer: viewer, pullRequest: pr, isOpen: true) },
                                  write: { pr in await writes.record(pr.id); throw limit }, isAllowed: { _ in allowed })
        let task = try #require(started)
        await gate.waitUntilEntered()
        if case .waiting(let seconds, let attempt) = batch.entries[0].status {
            #expect(seconds == 60 && attempt == 2)
        } else { Issue.record("Debe indicar la espera en el estado") }
        if scopeChange { allowed = false } else { batch.stop() }
        await gate.release()
        await task.value
        #expect(await writes.ids == ["PR_1"])
        #expect(batch.skippedCount == 2)
    }

    @Test("También recupera un rate limit de la lectura antes de enviar la aprobación")
    func limitedRead() async throws {
        let clock = ApprovalClock()
        let batch = PullRequestBatch(runner: clock.coordinator())
        batch.prepare([pr(1)], viewer: "me")
        let reads = BatchCalls()
        let writes = ApprovalCalls()
        let limit = try rateLimit(headers: "Retry-After: 4")
        let started = batch.start(.approve, read: { pr, viewer in
            await reads.record(pr.id)
            if await reads.ids.count == 1 { throw limit }
            return .init(viewer: viewer, pullRequest: pr, isOpen: true)
        }, write: { pr in await writes.record(pr.id, at: clock.date) }, isAllowed: { _ in true })
        await (try #require(started)).value
        #expect(await writes.times == [4])
        #expect(batch.succeededCount == 1)
    }

    @Test("Errores de permisos, validación y transporte no se reintentan", arguments: [403, 422, 502])
    func nonRetryable(status: Int) async throws {
        let clock = ApprovalClock()
        let batch = PullRequestBatch(runner: clock.coordinator())
        batch.prepare([pr(1), pr(2)], viewer: "me")
        let writes = BatchCalls()
        let response = try GitHubAPIResponse(Data("HTTP/2.0 \(status) Error\n\n{\"message\":\"Request rejected\"}".utf8))
        let failure = GitHubAPIError(response: response, detail: "Request rejected")
        let started = batch.start(.approve, read: { pr, viewer in .init(viewer: viewer, pullRequest: pr, isOpen: true) },
                                  write: { pr in await writes.record(pr.id); throw failure }, isAllowed: { _ in true })
        await (try #require(started)).value
        #expect(await writes.ids == ["PR_1", "PR_2"])
        #expect(batch.failedCount == 2 && batch.skippedCount == 0)
    }

    @Test("La aprobación individual comparte retries y valida sin imponer el criterio de Dependabot")
    func individualApproval() async throws {
        let clock = ApprovalClock()
        let coordinator = clock.coordinator()
        let person = pr(1, checks: .pending, mergeable: .unknown, author: "alice")
        let writes = ApprovalCalls()
        let limit = try rateLimit(headers: "Retry-After: 3")
        let result = try await coordinator.perform(person, viewer: "me", batch: false,
            read: { pr, viewer in .init(viewer: viewer, pullRequest: pr, isOpen: true) },
            write: { pr in
                await writes.record(pr.id, at: clock.date)
                if await writes.ids.count == 1 { throw limit }
            })
        if case .completed = result {} else { Issue.record("Debe aprobar el PR individual") }
        #expect(await writes.times == [0, 3])
    }

    @Test("Las aprobaciones individuales y los lotes que comparten cola no se ejecutan en paralelo")
    func sharedQueue() async throws {
        let clock = ApprovalClock()
        let coordinator = clock.coordinator()
        let batch = PullRequestBatch(runner: coordinator)
        batch.prepare([pr(1)], viewer: "me")
        let gate = BatchGate()
        let reads = BatchCalls()
        let writes = ApprovalCalls()
        let started = batch.start(.approve, read: { pr, viewer in
            await reads.record(pr.id)
            await gate.enter()
            return .init(viewer: viewer, pullRequest: pr, isOpen: true)
        }, write: { pr in await writes.record(pr.id, at: clock.date) }, isAllowed: { _ in true })
        let task = try #require(started)
        await gate.waitUntilEntered()
        let individual = Task {
            try await coordinator.perform(pr(2), viewer: "me", batch: false,
                read: { pr, viewer in
                    await reads.record(pr.id)
                    return .init(viewer: viewer, pullRequest: pr, isOpen: true)
                }, write: { pr in await writes.record(pr.id, at: clock.date) })
        }
        await Task.yield()
        #expect(await reads.ids == ["PR_1"])
        await gate.release()
        await task.value
        _ = try await individual.value
        #expect(await writes.ids == ["PR_1", "PR_2"])
        #expect(await writes.times == [0, 1])
    }

    @Test("Detener un lote encolado responde sin esperar a otra aprobación")
    func stopQueuedBatch() async throws {
        let clock = ApprovalClock()
        let coordinator = clock.coordinator()
        let gate = BatchGate()
        let individual = Task {
            try await coordinator.perform(pr(1), viewer: "me", batch: false,
                read: { pr, viewer in
                    await gate.enter()
                    return .init(viewer: viewer, pullRequest: pr, isOpen: true)
                }, write: { _ in })
        }
        await gate.waitUntilEntered()
        let batch = PullRequestBatch(runner: coordinator)
        batch.prepare([pr(2)], viewer: "me")
        let started = batch.start(.approve, read: { _, _ in Issue.record("No debe leer un lote detenido"); throw GH.Failure.noAttempts },
                                  write: { _ in Issue.record("No debe escribir") }, isAllowed: { _ in true })
        await Task.yield()
        batch.stop()
        await (try #require(started)).value
        #expect(batch.skippedCount == 1)
        await gate.release()
        _ = try await individual.value
    }

    private func rateLimit(headers: String = "", status: Int = 429) throws -> GitHubAPIError {
        let message = status == 422 ? "was submitted too quickly" : "secondary rate limit"
        let response = try GitHubAPIResponse(Data("HTTP/2.0 \(status) Error\n\(headers)\n\n{\"message\":\"\(message)\"}".utf8))
        return GitHubAPIError(response: response, detail: "secondary rate limit")
    }

    private func pr(_ number: Int, checks: CheckState = .success, mergeable: MergeableState = .mergeable,
                    author: String = "dependabot", draft: Bool = false, approved: Bool = false,
                    decision: ReviewDecision = .reviewRequired) -> PullRequest {
        PullRequest(id: "PR_\(number)", number: number,
                    title: number == 1 ? "Bump rubocop and rubocop-performance to the latest compatible versions" : "Bump dependency from 1.2.0 to 1.3.0",
                    url: URL(string: "https://github.com/org/api/pull/\(number)")!, repository: "org/api",
                    baseRefName: "main", headRefName: "update", author: Author(login: author, typename: author == "alice" ? "User" : "Bot"),
                    updatedAt: .now, isDraft: draft, checks: checks, reviewDecision: decision,
                    mergeable: mergeable, mergeStateStatus: .blocked, defaultMergeMethod: .squash,
                    authoredByMe: false, requestedFromMe: true, reviewedByMe: false, approvals: 0, approvedByMe: approved,
                    headRefOID: "commit-\(number)")
    }
}

private actor BatchCalls {
    private(set) var ids: [String] = []
    func record(_ id: String) { ids.append(id) }
}

private actor BatchGate {
    private var entered = false
    private var waiting: CheckedContinuation<Void, Never>?
    private var enteredWaiter: CheckedContinuation<Void, Never>?
    func enter() async {
        entered = true
        enteredWaiter?.resume()
        enteredWaiter = nil
        await withCheckedContinuation { waiting = $0 }
    }
    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { enteredWaiter = $0 }
    }
    func release() {
        waiting?.resume()
        waiting = nil
    }
}

@MainActor
private final class ApprovalClock {
    private(set) var date = Date(timeIntervalSince1970: 0)
    func advance(_ seconds: TimeInterval) { date.addTimeInterval(seconds) }
    func coordinator() -> GitHubActionRunner {
        GitHubActionRunner(now: { self.date }, sleep: { self.advance($0) })
    }
}

private actor ApprovalCalls {
    private(set) var ids: [String] = []
    private(set) var times: [TimeInterval] = []
    func record(_ id: String, at date: Date) {
        ids.append(id)
        times.append(date.timeIntervalSince1970)
    }
}

// Preparación abreviada para los tests de ejecución: selección explícita de todos.
@MainActor
extension PullRequestBatch {
    func toggleAllForTesting() {
        guard !isRunning else { return }
        let ids = selectedIDs.count == candidates.count ? selectedIDs : Set(candidates.map(\.id)).subtracting(selectedIDs)
        for id in ids { toggle(id) }
    }
    func prepare(_ prs: [PullRequest], viewer: String) {
        enter(Self.candidates(reviews: prs, merges: []), viewer: viewer)
        toggleAllForTesting()
    }
    func reconcile(_ prs: [PullRequest]) {
        reconcile(Self.candidates(reviews: prs, merges: []), viewer: viewer)
    }
}
