import AppKit
import SwiftUI
import Testing
@testable import WorkBuddy

@Suite("Aprobaciones de Dependabot en lote")
@MainActor
struct DependabotApprovalBatchTests {
    @Test("Prepara sólo Dependabot elegibles, deduplica y permite desmarcar sin ampliar el lote")
    func selection() {
        let ready = pr(1)
        var noCommit = pr(2)
        noCommit.headRefOID = nil
        let candidates = [ready, ready, noCommit, pr(3, checks: .pending), pr(4, mergeable: .conflicting),
                          pr(5, author: "renovate[bot]"), pr(6, draft: true), pr(7, approved: true),
                          pr(8, decision: .approved), pr(9, mergeable: .unknown)]
        let batch = DependabotApprovalBatch()
        batch.prepare(candidates, viewer: "me")
        #expect(batch.entries.map(\.id) == [ready.id])
        #expect(batch.selectedIDs == [ready.id])
        batch.toggle("missing")
        #expect(batch.selectedIDs == [ready.id])
        batch.toggle(ready.id)
        #expect(batch.selectedIDs.isEmpty)
        let empty = batch.start(read: { _, _ in fatalError() }, approve: { _ in fatalError() }, isAllowed: { _ in true })
        #expect(empty == nil)
        batch.toggleAll()
        #expect(batch.selectedIDs == [ready.id])
        batch.toggleAll()
        #expect(batch.selectedIDs.isEmpty)
    }

    @Test("Revalida el commit, la cuenta, CI, draft y aprobación antes de escribir")
    func validation() {
        let original = pr(1)
        func reason(_ current: PullRequest?, open: Bool = true, viewer: String = "me") -> DependabotApprovalBatch.SkipReason? {
            DependabotApprovalBatch.skipReason(for: original, snapshot: .init(viewer: viewer, pullRequest: current, isOpen: open), viewer: "me")
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
        #expect(reason(pr(1, author: "renovate[bot]")) == .notReady)
    }

    @Test("El refresh retira los que dejan de cumplir el criterio sin agregar PRs ni resetear la selección")
    func reconciliation() {
        let batch = DependabotApprovalBatch()
        batch.prepare([pr(1), pr(2), pr(3), pr(4)], viewer: "me")
        batch.toggle("PR_2")
        var changed = pr(3)
        changed.headRefOID = "new"
        batch.reconcile([pr(1), pr(2), changed, pr(4, checks: .pending), pr(5)])
        #expect(batch.entries.map(\.id) == ["PR_1", "PR_2"])
        #expect(batch.selectedIDs == ["PR_1"])
        batch.reconcile([])
        #expect(batch.entries.isEmpty && batch.selectedIDs.isEmpty)
    }

    @Test("Resultados parciales: nunca reintenta una aprobación incierta y continúa el lote")
    func partialResults() async throws {
        let batch = DependabotApprovalBatch()
        batch.prepare([pr(1), pr(2), pr(3), pr(4)], viewer: "me")
        batch.toggle("PR_4")
        let calls = BatchCalls()
        var approved: [String] = []
        var finished = 0
        let started = batch.start(read: { pr, viewer in
            var current = pr
            if pr.number == 2 { current.headRefOID = "new" }
            return .init(viewer: viewer, pullRequest: current, isOpen: true)
        }, approve: { pr in
            await calls.record(pr.id)
            if pr.number == 3 { throw GH.Failure.commandFailed(exitCode: 1, stderr: "HTTP 502") }
        }, isAllowed: { _ in true }, didApprove: { approved.append($0.id) }, didFinish: { finished += 1 })
        let task = try #require(started)
        #expect(batch.phase == .running)
        let duplicate = batch.start(read: { _, _ in fatalError() }, approve: { _ in fatalError() }, isAllowed: { _ in true })
        #expect(duplicate == nil)
        batch.toggleAll()
        #expect(batch.selectedIDs == ["PR_1", "PR_2", "PR_3"])
        await task.value
        #expect(batch.phase == .finished)
        #expect(batch.entries.count == 3)
        #expect(batch.completedCount == 3)
        #expect(batch.approvedCount == 1 && batch.skippedCount == 1 && batch.failedCount == 1)
        #expect(await calls.ids == ["PR_1", "PR_3"])
        #expect(approved == ["PR_1"] && finished == 1)
    }

    @Test("Un cambio de alcance durante la lectura omite la escritura")
    func scopeDuringRead() async throws {
        let batch = DependabotApprovalBatch()
        batch.prepare([pr(1)], viewer: "me")
        let gate = BatchGate()
        var allowed = true
        let started = batch.start(read: { pr, viewer in
            await gate.enter()
            return .init(viewer: viewer, pullRequest: pr, isOpen: true)
        }, approve: { _ in Issue.record("No debe escribir después de cambiar el alcance") }, isAllowed: { _ in allowed })
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
        let batch = DependabotApprovalBatch()
        batch.prepare([pr(1), pr(2)], viewer: "me")
        let gate = BatchGate()
        let writes = BatchCalls()
        let started = batch.start(read: { pr, viewer in
            if !duringWrite { await gate.enter() }
            return .init(viewer: viewer, pullRequest: pr, isOpen: true)
        }, approve: { pr in
            await writes.record(pr.id)
            if duringWrite { await gate.enter() }
        }, isAllowed: { _ in true })
        let task = try #require(started)
        await gate.waitUntilEntered()
        batch.isPresented = false
        batch.prepare([pr(9)], viewer: "other")
        batch.reconcile([])
        #expect(batch.isPresented)
        #expect(batch.viewer == "me" && batch.entries.map(\.id) == ["PR_1", "PR_2"])
        batch.stop()
        await gate.release()
        await task.value
        #expect(await writes.ids == (duringWrite ? ["PR_1"] : []))
        #expect(batch.approvedCount == (duringWrite ? 1 : 0))
        #expect(batch.skippedCount == (duringWrite ? 1 : 2))
    }

    @Test("Un cambio de cuenta detiene los PRs restantes")
    func accountChange() async throws {
        let batch = DependabotApprovalBatch()
        batch.prepare([pr(1), pr(2)], viewer: "me")
        let calls = BatchCalls()
        let started = batch.start(read: { pr, _ in
            await calls.record(pr.id)
            return .init(viewer: "other", pullRequest: pr, isOpen: true)
        }, approve: { _ in Issue.record("No debe aprobar con otra cuenta") }, isAllowed: { _ in true })
        let task = try #require(started)
        await task.value
        #expect(await calls.ids == ["PR_1"])
        #expect(batch.skippedCount == 2)
        if case .skipped(.accountChanged) = batch.entries[0].status {} else { Issue.record("Cuenta cambiada") }
    }

    @Test("Consulta GitHub por ID y conserva el commit y la aprobación personal")
    func freshQuery() async throws {
        let snapshot = try await DependabotApprovalCheck.fetch(pr(1), viewer: "me") { arguments in
            let query = try #require(arguments.first { $0.hasPrefix("query=") })
            #expect(query.contains("node(id: $id)"))
            #expect(query.contains("state") && query.contains("headRefOid") && query.contains("mergeable"))
            #expect(arguments.contains("id=PR_1") && arguments.contains("reviewAuthor=me"))
            return Data(#"{"data":{"viewer":{"login":"me"},"node":{"id":"PR_1","number":1,"title":"Update","url":"https://github.com/org/api/pull/1","repository":{"nameWithOwner":"org/api"},"author":{"login":"dependabot","__typename":"Bot"},"state":"OPEN","baseRefName":"main","headRefName":"update","headRefOid":"commit-1","updatedAt":"2026-09-30T00:00:00Z","mergeable":"MERGEABLE","isDraft":false,"myReview":{"nodes":[{"author":{"login":"me"},"state":"APPROVED"}]},"commits":{"nodes":[{"commit":{"statusCheckRollup":{"state":"SUCCESS"}}}]}}}}"#.utf8)
        }
        #expect(snapshot.isOpen)
        #expect(snapshot.pullRequest?.headRefOID == "commit-1")
        #expect(snapshot.pullRequest?.approvedByMe == true)
        #expect(DependabotApprovalBatch.skipReason(for: pr(1), snapshot: snapshot, viewer: "me") == .alreadyApproved)
        let args = GitHubWrite.approveCommit(repository: "org/api", number: 1, commitID: "commit-1").arguments
        #expect(args == ["api", "repos/org/api/pulls/1/reviews", "--method", "POST", "-f", "event=APPROVE", "-f", "commit_id=commit-1"])
    }

    @Test("Una lectura fallida conserva el error y no escribe")
    func readFailure() async throws {
        let batch = DependabotApprovalBatch()
        batch.prepare([pr(1)], viewer: "me")
        let started = batch.start(read: { _, _ in throw GH.Failure.noAttempts },
                                  approve: { _ in Issue.record("No debe escribir sin lectura válida") }, isAllowed: { _ in true })
        let task = try #require(started)
        await task.value
        #expect(batch.failedCount == 1 && batch.approvedCount == 0)
    }

    /// Exportación opt-in para revisar la vista real sin ejecutar acciones en GitHub.
    @Test("Renderiza selección y resultados a 420 px en ambos idiomas y apariencias")
    func visualPreview() async throws {
        guard let directory = ProcessInfo.processInfo.environment["WORK_BUDDY_BATCH_PREVIEW_DIR"] else { return }
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let originalLanguage = Localization.shared.language
        defer { Localization.shared.setLanguage(originalLanguage, defaults: UserDefaults(suiteName: "batch-preview")!) }
        for language in [AppLanguage.spanish, .english] {
            Localization.shared.setLanguage(language, defaults: UserDefaults(suiteName: "batch-preview")!)
            let batch = DependabotApprovalBatch()
            batch.prepare((1...8).map { pr($0) }, viewer: "me")
            batch.toggle("PR_2")
            for scheme in [ColorScheme.light, .dark] {
                try render(batch, directory: directory, name: "select-\(language.rawValue)-\(scheme)", scheme: scheme)
            }
            batch.toggleAll()
            batch.toggleAll()
            try render(batch, directory: directory, name: "empty-selection-\(language.rawValue)", scheme: .light)
            batch.toggleAll()
            batch.toggle("PR_2")
            let started = batch.start(read: { pr, viewer in
                var current = pr
                if pr.number == 3 { current.headRefOID = "changed" }
                return .init(viewer: viewer, pullRequest: current, isOpen: true)
            }, approve: { pr in
                if pr.number == 4 { throw GH.Failure.commandFailed(exitCode: 1, stderr: "GitHub is temporarily unavailable") }
            }, isAllowed: { _ in true })
            let task = try #require(started)
            await task.value
            for scheme in [ColorScheme.light, .dark] {
                try render(batch, directory: directory, name: "result-\(language.rawValue)-\(scheme)", scheme: scheme)
            }

            let running = DependabotApprovalBatch()
            running.prepare((1...8).map { pr($0) }, viewer: "me")
            let gate = BatchGate()
            let progressStarted = running.start(read: { pr, viewer in
                if pr.number == 3 { await gate.enter() }
                return .init(viewer: viewer, pullRequest: pr, isOpen: true)
            }, approve: { _ in }, isAllowed: { _ in true })
            let progressTask = try #require(progressStarted)
            await gate.waitUntilEntered()
            for scheme in [ColorScheme.light, .dark] {
                try render(running, directory: directory, name: "running-\(language.rawValue)-\(scheme)", scheme: scheme)
            }
            running.stop()
            await gate.release()
            await progressTask.value
        }
    }

    private func render(_ batch: DependabotApprovalBatch, directory: String, name: String, scheme: ColorScheme) throws {
        // ImageRenderer omite ScrollView y controles nativos. Un hosting view
        // fuera de pantalla incluye ambos sin abrir ventanas ni tocar GitHub.
        let view = NSHostingView(rootView: DependabotApprovalBatchView(batch: batch, start: {}, close: {}, newBatch: {})
            .frame(width: 420, height: 430).environment(\.colorScheme, scheme))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 430),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        window.contentView = view
        view.setFrameSize(NSSize(width: 420, height: 430))
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(name).png"))
    }

    private func pr(_ number: Int, checks: CheckState = .success, mergeable: MergeableState = .mergeable,
                    author: String = "dependabot", draft: Bool = false, approved: Bool = false,
                    decision: ReviewDecision = .reviewRequired) -> PullRequest {
        PullRequest(id: "PR_\(number)", number: number,
                    title: number == 1 ? "Bump rubocop and rubocop-performance to the latest compatible versions" : "Bump dependency from 1.2.0 to 1.3.0",
                    url: URL(string: "https://github.com/org/api/pull/\(number)")!, repository: "org/api",
                    baseRefName: "main", headRefName: "update", author: Author(login: author, typename: "Bot"),
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
