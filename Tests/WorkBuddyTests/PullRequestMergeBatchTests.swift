import AppKit
import SwiftUI
import Testing
@testable import WorkBuddy

@Suite("Batch integrado y merge")
@MainActor
struct PullRequestMergeBatchTests {
    @Test("Selección mixta: incluye personas y bots, prioriza merge y ejecuta cada subconjunto por separado")
    func mixedSelection() async throws {
        let review = fixture(1, author: "alice", checks: .pending)
        let merge = fixture(2, own: true, mergeState: .clean)
        let foreignMerge = fixture(3, author: "alice", mergeState: .clean)
        let candidates = PullRequestBatch.candidates(reviews: [review, review, merge], merges: [merge, foreignMerge])
        #expect(candidates.map(\.id) == [merge.id, review.id])
        let clock = MergeClock()
        let batch = PullRequestBatch(runner: clock.runner())
        batch.enter(candidates, viewer: "me")
        #expect(batch.selectedIDs.isEmpty)
        batch.toggleAllForTesting()
        #expect(batch.selected(.approve).map(\.id) == [review.id])
        #expect(batch.selected(.merge).map(\.id) == [merge.id])
        let calls = MergeCalls()
        let approved = batch.start(.approve, read: fresh,
                                   write: { await calls.record($0.id, date: clock.date) }, isAllowed: { _ in true })
        #expect(batch.selectedIDs == [merge.id])
        await (try #require(approved)).value
        #expect(batch.succeededCount == 1)
        #expect(batch.selectedIDs == [merge.id])
        let merged = batch.start(.merge, read: fresh,
                                 write: { await calls.record($0.id, date: clock.date) }, isAllowed: { _ in true })
        await (try #require(merged)).value
        #expect(await calls.ids == [review.id, merge.id])
        #expect(await calls.times == [0, 1])
        if case .completed(.merge) = batch.entries[0].status {} else { Issue.record("Resultado de merge") }
    }

    @Test("El refresh conserva selecciones por commit, acción, base y método; agrega nuevos sin seleccionar")
    func liveSelection() {
        let batch = PullRequestBatch()
        let review = fixture(1, author: "alice")
        let merges = [fixture(2, own: true, mergeState: .clean), fixture(3, mergeState: .clean), fixture(4, mergeState: .clean)]
        batch.enter(PullRequestBatch.candidates(reviews: [review], merges: merges), viewer: "me")
        batch.toggleAllForTesting()
        let changed = [fixture(2, own: true, mergeState: .clean, head: "new"),
                       fixture(3, mergeState: .clean, method: .rebase),
                       fixture(4, mergeState: .clean, base: "release"), fixture(5, mergeState: .clean)]
        batch.reconcile(PullRequestBatch.candidates(reviews: [review], merges: changed), viewer: "me")
        #expect(batch.selectedIDs == [review.id])
        #expect(batch.candidates.count == 5)
        let promoted = fixture(1, mergeState: .clean)
        batch.reconcile(PullRequestBatch.candidates(reviews: [], merges: [promoted]), viewer: "me")
        #expect(batch.selectedIDs.isEmpty)
    }

    @Test("El lote en ejecución queda fijo aunque lleguen PRs nuevos; conserva la selección del otro grupo")
    func arrivalsDuringRun() async throws {
        let batch = PullRequestBatch()
        let review = fixture(1, author: "alice")
        let merge = fixture(2, own: true, mergeState: .clean)
        let gate = MergeGate()
        batch.enter(PullRequestBatch.candidates(reviews: [review], merges: [merge]), viewer: "me")
        batch.toggleAllForTesting()
        let calls = MergeCalls()
        let started = batch.start(.approve, read: { pr, viewer in
            await gate.enter()
            return .init(viewer: viewer, pullRequest: pr, isOpen: true)
        }, write: { await calls.record($0.id) }, isAllowed: { _ in true })
        let task = try #require(started)
        await gate.waitUntilEntered()
        batch.reconcile(PullRequestBatch.candidates(reviews: [review, fixture(3)], merges: [merge, fixture(4, mergeState: .clean)]), viewer: "me")
        #expect(batch.candidates.count == 4)
        #expect(batch.selectedIDs == [merge.id])
        #expect(batch.entries.map(\.id) == [review.id])
        batch.toggleAllForTesting()
        #expect(batch.selectedIDs == [merge.id])
        await gate.release()
        await task.value
        #expect(await calls.ids == [review.id])
    }

    @Test("Merge revalida cuenta, head, método y condiciones de GitHub")
    func mergeValidation() {
        let original = fixture(1, mergeState: .clean)
        func reason(_ current: PullRequest?, viewer: String = "me", open: Bool = true, merged: Bool = false) -> PullRequestActionSkipReason? {
            PullRequestBatchAction.merge.skipReason(for: original,
                snapshot: .init(viewer: viewer, pullRequest: current, isOpen: open, isMerged: merged), viewer: "me", batch: true)
        }
        #expect(reason(original) == nil)
        #expect(reason(original, viewer: "other") == .accountChanged)
        #expect(reason(nil) == .closed)
        #expect(reason(original, open: false) == .closed)
        #expect(reason(original, open: false, merged: true) == .alreadyMerged)
        #expect(reason(fixture(1, mergeState: .clean, head: "new")) == .changed)
        #expect(reason(fixture(1, mergeState: .clean, head: nil)) == .changed)
        #expect(reason(fixture(1, mergeState: .clean, method: .rebase)) == .methodChanged)
        #expect(reason(fixture(1, mergeState: .clean, method: nil)) == .methodChanged)
        #expect(reason(fixture(1, mergeState: .clean, base: "release")) == .changed)
        for state in [MergeStateStatus.blocked, .behind, .dirty, .draft, .unknown] {
            #expect(reason(fixture(1, mergeState: state)) == .notReady)
        }
        #expect(reason(fixture(1, mergeState: .clean, mergeable: .unknown)) == .notReady)
        #expect(reason(fixture(1, mergeState: .clean, draft: true)) == .notReady)
        #expect(reason(fixture(1, mergeState: .unstable, checks: .failure)) == nil)
        #expect(reason(fixture(1, mergeState: .hasHooks)) == nil)
    }

    @Test("El primer merge puede bloquear el siguiente; se vuelve a leer antes de escribir")
    func mergeAffectsNext() async throws {
        let batch = PullRequestBatch(runner: MergeClock().runner())
        let first = fixture(1, mergeState: .clean)
        let second = fixture(2, mergeState: .clean)
        let blocked = fixture(2, mergeState: .behind)
        batch.enter(PullRequestBatch.candidates(reviews: [], merges: [first, second]), viewer: "me")
        batch.toggleAllForTesting()
        let calls = MergeCalls()
        let started = batch.start(.merge, read: { pr, viewer in
            .init(viewer: viewer, pullRequest: pr.id == second.id ? blocked : pr, isOpen: true)
        }, write: { await calls.record($0.id) }, isAllowed: { _ in true })
        await (try #require(started)).value
        #expect(await calls.ids == [first.id])
        #expect(batch.succeededCount == 1 && batch.skippedCount == 1)
    }

    @Test("Merge respeta rate limits y detecta un merge ya registrado antes de repetir", arguments: [false, true])
    func mergeRetry(alreadyMerged: Bool) async throws {
        let clock = MergeClock()
        let batch = PullRequestBatch(runner: clock.runner())
        let pr = fixture(1, mergeState: .clean)
        batch.enter(PullRequestBatch.candidates(reviews: [], merges: [pr]), viewer: "me")
        batch.toggleAllForTesting()
        let writes = MergeCalls()
        let reads = MergeCalls()
        let limit = try GitHubAPIError(response: GitHubAPIResponse(Data("HTTP/2.0 429 Error\nRetry-After: 7\n\n{}".utf8)), detail: "rate limit")
        let started = batch.start(.merge, read: { pr, viewer in
            await reads.record(pr.id)
            let readCount = await reads.count()
            let merged = alreadyMerged && readCount > 1
            return .init(viewer: viewer, pullRequest: pr, isOpen: !merged, isMerged: merged)
        }, write: { pr in
            await writes.record(pr.id, date: clock.date)
            if await writes.count() == 1 { throw limit }
        }, isAllowed: { _ in true })
        await (try #require(started)).value
        #expect(batch.succeededCount == 1 && batch.failedCount == 0)
        #expect(await writes.times == (alreadyMerged ? [0] : [0, 7]))
        #expect(clock.date.timeIntervalSince1970 == 7)
    }

    @Test("Un 409 por cambio de SHA no se reintenta y conserva el resultado fallido")
    func mergeConflict() async throws {
        let batch = PullRequestBatch()
        batch.enter(PullRequestBatch.candidates(reviews: [], merges: [fixture(1, mergeState: .clean)]), viewer: "me")
        batch.toggleAllForTesting()
        let calls = MergeCalls()
        let error = try GitHubAPIError(response: GitHubAPIResponse(Data("HTTP/2.0 409 Conflict\n\n{}".utf8)), detail: "head changed")
        let started = batch.start(.merge, read: fresh, write: { pr in await calls.record(pr.id); throw error }, isAllowed: { _ in true })
        await (try #require(started)).value
        #expect(await calls.count() == 1 && batch.failedCount == 1)
    }

    @Test("Escribe el SHA y el método exactos; un HTTP exitoso sin merged=true no cuenta como merge")
    func mergeTransport() async throws {
        let pr = fixture(1, mergeState: .clean)
        let calls = MergeCalls()
        try await GitHubActionRunner.submit(pr, action: .merge) { arguments in
            #expect(arguments == ["api", "repos/org/api/pulls/1/merge", "--method", "PUT", "-f", "sha=commit-1", "-f", "merge_method=squash"])
            await calls.record("merge")
            return Data(#"{"merged":true,"message":"merged"}"#.utf8)
        }
        await #expect(throws: (any Error).self) {
            try await GitHubActionRunner.submit(pr, action: .merge) { _ in Data(#"{"merged":false,"message":"blocked"}"#.utf8) }
        }
        await #expect(throws: (any Error).self) {
            try await GitHubActionRunner.submit(pr, action: .merge) { _ in Data(#"{"message":"queued"}"#.utf8) }
        }
        #expect(await calls.count() == 1)
    }

    @Test("La lectura de merge conserva estado final, método y cuentas de máquina configuradas")
    func mergeQuery() async throws {
        let snapshot = try await PullRequestActionCheck.fetch(fixture(1), viewer: "me", action: .merge, machineAccounts: ["build-bot"]) { args in
            let query = try #require(args.first { $0.hasPrefix("query=") })
            #expect(query.contains("mergeStateStatus") && query.contains("headRefOid") && query.contains("viewerDefaultMergeMethod"))
            return Data(#"{"data":{"viewer":{"login":"me"},"node":{"id":"batch-1","number":1,"title":"Update","url":"https://github.com/org/api/pull/1","repository":{"nameWithOwner":"org/api","viewerDefaultMergeMethod":"SQUASH"},"author":{"login":"build-bot","__typename":"User"},"state":"MERGED","baseRefName":"main","headRefName":"update","headRefOid":"commit-1","updatedAt":"2026-09-30T00:00:00Z","mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","isDraft":false,"commits":{"nodes":[{"commit":{"statusCheckRollup":{"state":"SUCCESS"}}}]}}}}"#.utf8)
        }
        #expect(snapshot.isMerged && !snapshot.isOpen)
        #expect(snapshot.pullRequest?.author.isBot == true)
        #expect(snapshot.pullRequest?.defaultMergeMethod == .squash)
    }

    @Test("La cola del store expone ambas acciones y limpia la selección al cambiar de cuenta")
    func storeSelection() {
        let review = fixture(1, author: "alice")
        let merge = fixture(2, own: true, mergeState: .clean)
        let store = ReviewQueueStore.preview(reviews: [review], merges: [merge])
        store.toggleBatchSelection()
        store.batch.toggleAllForTesting()
        #expect(store.batch.selected(.approve).count == 1)
        #expect(store.batch.selected(.merge).count == 1)
        store.reconcileBatch()
        #expect(store.batch.selectedIDs.count == 2)
        store.batch.reconcile(store.batchCandidates, viewer: "another-account")
        #expect(store.batch.selectedIDs.isEmpty)
    }

    @Test("Preview del panel real: filas originales con checkbox, selección mixta, progreso y resultados")
    func visualPreview() async throws {
        guard let directory = ProcessInfo.processInfo.environment["WORK_BUDDY_BATCH_PREVIEW_DIR"] else { return }
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let defaults = UserDefaults(suiteName: "batch-preview-\(UUID().uuidString)")!
        defaults.set(false, forKey: "appearance.showEmptySections")
        defaults.set("", forKey: "github.collapsedSections")
        let language = Localization.shared.language
        defer { Localization.shared.setLanguage(language, defaults: defaults) }
        for language in [AppLanguage.spanish, .english] {
            Localization.shared.setLanguage(language, defaults: defaults)
            let reviews = [fixture(1, author: "alice"), fixture(2)]
            let merges = [fixture(3, own: true, mergeState: .clean), fixture(4, mergeState: .clean)]
            let store = ReviewQueueStore.preview(reviews: reviews, merges: merges)
            for scheme in [ColorScheme.light, .dark] {
                try render(store, defaults: defaults, directory: directory, name: "normal-\(language.rawValue)-\(scheme)", scheme: scheme)
            }
            store.toggleBatchSelection()
            try render(store, defaults: defaults, directory: directory, name: "empty-\(language.rawValue)", scheme: .light)
            for id in ["batch-1", "batch-2", "batch-3"] { store.batch.toggle(id) }
            for scheme in [ColorScheme.light, .dark] {
                try render(store, defaults: defaults, directory: directory, name: "mixed-\(language.rawValue)-\(scheme)", scheme: scheme)
            }
            let gate = MergeGate()
            let started = store.batch.start(.approve, read: { pr, viewer in
                if pr.number == 1 { await gate.enter() }
                return .init(viewer: viewer, pullRequest: pr, isOpen: true)
            }, write: { pr in
                if pr.number == 2 { throw GH.Failure.commandFailed(exitCode: 1, stderr: "GitHub unavailable") }
            }, isAllowed: { _ in true })
            let task = try #require(started)
            await gate.waitUntilEntered()
            for scheme in [ColorScheme.light, .dark] {
                try render(store, defaults: defaults, directory: directory, name: "running-\(language.rawValue)-\(scheme)", scheme: scheme)
            }
            await gate.release()
            await task.value
            for scheme in [ColorScheme.light, .dark] {
                try render(store, defaults: defaults, directory: directory, name: "result-\(language.rawValue)-\(scheme)", scheme: scheme)
            }
        }
    }

    private func render(_ store: ReviewQueueStore, defaults: UserDefaults, directory: String, name: String, scheme: ColorScheme) throws {
        let view = NSHostingView(rootView: GitHubSectionView(store: store, showRepositories: {})
            .frame(width: 420, height: 460)
            .background(scheme == .dark ? Color(white: 0.12) : Color.white)
            .environment(\.colorScheme, scheme).defaultAppStorage(defaults))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 460), styleMask: .borderless, backing: .buffered, defer: false)
        let appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)!
        window.appearance = appearance
        window.contentView = view
        view.setFrameSize(NSSize(width: 420, height: 460))
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        appearance.performAsCurrentDrawingAppearance {
            view.cacheDisplay(in: view.bounds, to: bitmap)
        }
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(name).png"))
    }

    private var fresh: @Sendable (PullRequest, String) async throws -> PullRequestActionCheck.Snapshot {
        { .init(viewer: $1, pullRequest: $0, isOpen: true) }
    }
}

func fixture(_ number: Int, author: String = "dependabot", own: Bool = false,
             mergeState: MergeStateStatus = .blocked, checks: CheckState = .success,
             head: String? = "default", method: MergeMethod? = .squash, base: String = "main",
             mergeable: MergeableState = .mergeable, draft: Bool = false) -> PullRequest {
    PullRequest(id: "batch-\(number)", number: number,
                title: own ? "Improve search and navigation" : "Update dependencies and fix compatibility",
                url: URL(string: "https://github.com/org/api/pull/\(number)")!, repository: "org/api",
                baseRefName: base, headRefName: "update", author: Author(login: own ? "me" : author, typename: own || author == "alice" ? "User" : "Bot"),
                updatedAt: .now, isDraft: draft, checks: checks, reviewDecision: .reviewRequired,
                mergeable: mergeable, mergeStateStatus: mergeState, defaultMergeMethod: method,
                authoredByMe: own, requestedFromMe: true, reviewedByMe: false, approvals: 0, approvedByMe: false,
                headRefOID: head == "default" ? "commit-\(number)" : head)
}

@MainActor
private final class MergeClock {
    private(set) var date = Date(timeIntervalSince1970: 0)
    func runner() -> GitHubActionRunner { GitHubActionRunner(now: { self.date }, sleep: { self.date.addTimeInterval($0) }) }
}
private actor MergeCalls {
    private(set) var ids: [String] = []
    private(set) var times: [TimeInterval] = []
    func record(_ id: String, date: Date = Date(timeIntervalSince1970: 0)) { ids.append(id); times.append(date.timeIntervalSince1970) }
    func count() -> Int { ids.count }
}
private actor MergeGate {
    private var entered = false
    private var continuation: CheckedContinuation<Void, Never>?
    private var observer: CheckedContinuation<Void, Never>?
    func enter() async {
        entered = true
        observer?.resume(); observer = nil
        await withCheckedContinuation { continuation = $0 }
    }
    func waitUntilEntered() async { if !entered { await withCheckedContinuation { observer = $0 } } }
    func release() { continuation?.resume(); continuation = nil }
}
