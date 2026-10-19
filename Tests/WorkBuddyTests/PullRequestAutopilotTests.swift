import Foundation
import Testing
@testable import WorkBuddy

@Suite("Autopilot de Dependabot")
@MainActor
struct PullRequestAutopilotTests {
    @Test("Un error de lectura permite volver a comprobar el mismo PR al pulsar Start")
    func readFailureCanResume() async {
        let autopilot = PullRequestAutopilot(runner: AutopilotClock().runner())
        let calls = AutopilotCalls()
        let prs = candidates([fixture(1)])
        autopilot.enable(prs, viewer: "me", operations: .init(
            read: { _, _ in throw GH.Failure.noAttempts },
            write: { _ in Issue.record("La lectura falló: no debe escribir") }))
        await autopilot.waitUntilIdle()
        #expect(!autopilot.isEnabled && autopilot.queue.count == 1)
        autopilot.enable(prs, viewer: "me", operations: operations(calls))
        await autopilot.waitUntilIdle()
        #expect(await calls.values.count == 1)
    }

    @Test("Cambiar el filtro de automatización pausa hasta volver a pulsar Start")
    func scopePause() {
        let store = ReviewQueueStore.preview(reviews: [], merges: [])
        let suite = UserDefaults.standard
        let keys = ["github.automationFilter"]
        let saved = keys.map { suite.object(forKey: $0) }
        defer { for (key, value) in zip(keys, saved) { suite.set(value, forKey: key) } }
        store.setAutopilotEnabled(true)
        #expect(store.autopilot.isEnabled)
        store.setAutomationFilter(.excludingAutomation)
        #expect(!store.autopilot.isEnabled && store.autopilot.notice != nil)
        #expect(store.autopilot.isPresented)
        store.setAutopilotEnabled(true)
        #expect(store.autopilot.isEnabled && store.autopilot.notice == nil)
        store.setAutopilotEnabled(false)
    }

    private func candidates(_ prs: [PullRequest]) -> [PullRequestBatch.Candidate] {
        PullRequestBatch.candidates(reviews: prs, merges: prs.filter(\.canMerge))
    }
    private func operations(_ calls: AutopilotCalls) -> PullRequestAutopilot.Operations {
        .init(read: { .init(viewer: $1, pullRequest: $0.pullRequest, isOpen: true) },
              write: { await calls.append($0.fingerprint) })
    }

    private func date(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }
    private func calendar(_ timeZone: String = "America/Montevideo") -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timeZone)!
        return calendar
    }

    @Test("Se apaga a medianoche aun sin trabajo ni refresh, usando el día local", arguments: [
        ("America/Montevideo", "2026-10-19T23:59:59-03:00", "2026-10-20T00:00:00-03:00"),
        ("America/Montevideo", "2026-10-19T00:00:00-03:00", "2026-10-20T00:00:00-03:00"),
        ("America/New_York", "2026-03-08T00:00:00-05:00", "2026-03-09T00:00:00-04:00"),
        ("America/New_York", "2026-11-01T00:00:00-04:00", "2026-11-02T00:00:00-05:00")
    ])
    func midnightWhileIdle(timeZone: String, start: String, midnight: String) throws {
        let clock = AutopilotClock()
        clock.date = date(start)
        var scheduled: Timer?
        let autopilot = PullRequestAutopilot(now: { clock.date }, calendar: calendar(timeZone),
                                            scheduleTimer: { scheduled = $0 })
        autopilot.enable([], viewer: "me", operations: operations(AutopilotCalls()))
        let timer = try #require(scheduled)
        #expect(timer.fireDate == date(midnight))
        clock.date = date(midnight).addingTimeInterval(-1)
        autopilot.reconcile([], viewer: "me")
        #expect(autopilot.isEnabled)
        clock.date = date(midnight)
        timer.fire()
        #expect(!autopilot.isActive && autopilot.isPresented && autopilot.history.isEmpty)
        #expect(!timer.isValid)

        // El corte no se revierte por un refresh; Start habilita un día nuevo.
        autopilot.reconcile([], viewer: "me")
        #expect(!autopilot.isEnabled)
        autopilot.enable([], viewer: "me", operations: operations(AutopilotCalls()))
        #expect(autopilot.isEnabled && scheduled !== timer)
        #expect(scheduled?.fireDate == calendar(timeZone).date(byAdding: .day, value: 1, to: date(midnight)))
        autopilot.stop()
        #expect(scheduled?.isValid == false)
    }

    @Test("Una lectura que termina después de medianoche no envía la acción aunque el timer siga pendiente")
    func midnightDuringRead() async {
        let clock = AutopilotClock()
        clock.date = date("2026-10-19T23:59:59-03:00")
        let autopilot = PullRequestAutopilot(runner: clock.runner(), now: { clock.date },
                                            calendar: calendar(), scheduleTimer: { _ in })
        let gate = AutopilotGate()
        let calls = AutopilotCalls()
        autopilot.enable(candidates([fixture(1), fixture(2)]), viewer: "me", operations: .init(
            read: { candidate, viewer in
                await gate.enter()
                return .init(viewer: viewer, pullRequest: candidate.pullRequest, isOpen: true)
            }, write: { await calls.append($0.id) }))
        await gate.wait()
        clock.date = date("2026-10-20T00:00:00-03:00")
        await gate.release()
        await autopilot.waitUntilIdle()
        #expect(!autopilot.isActive && autopilot.queue.count == 2)
        if case .skipped(.stopped)? = autopilot.history.last?.status {} else { Issue.record("Debe indicar el corte de Autopilot") }
        #expect(await calls.values.isEmpty)
    }

    @Test("El corte a medianoche deja terminar una escritura enviada y conserva los pendientes")
    func midnightDuringWrite() async throws {
        let clock = AutopilotClock()
        clock.date = date("2026-10-19T23:59:59-03:00")
        var scheduled: Timer?
        let autopilot = PullRequestAutopilot(runner: clock.runner(), now: { clock.date },
                                            calendar: calendar(), scheduleTimer: { scheduled = $0 })
        let gate = AutopilotGate()
        let calls = AutopilotCalls()
        autopilot.enable(candidates([fixture(1), fixture(2)]), viewer: "me", operations: .init(
            read: { .init(viewer: $1, pullRequest: $0.pullRequest, isOpen: true) },
            write: { candidate in
                await calls.append(candidate.id)
                if candidate.id == "batch-1" { await gate.enter() }
            }))
        await gate.wait()
        clock.date = date("2026-10-20T00:00:00-03:00")
        try #require(scheduled).fire()
        #expect(!autopilot.isEnabled && autopilot.current?.id == "batch-1")
        await gate.release()
        await autopilot.waitUntilIdle()
        #expect(!autopilot.isActive && autopilot.queue.map(\.id) == ["batch-2"])
        if case .completed(.approve)? = autopilot.history.last?.status {} else { Issue.record("Debe registrar la aprobación enviada") }
        #expect(await calls.values == ["batch-1"])
    }

    @Test("El cooldown que cruza medianoche detiene la cola antes de leer el próximo PR")
    func midnightDuringCooldown() async {
        let clock = AutopilotClock()
        clock.date = date("2026-10-19T23:59:59-03:00")
        let autopilot = PullRequestAutopilot(runner: clock.runner(), now: { clock.date },
                                            calendar: calendar(), scheduleTimer: { _ in })
        let reads = AutopilotCalls()
        let calls = AutopilotCalls()
        autopilot.enable(candidates([fixture(1), fixture(2)]), viewer: "me", operations: .init(
            read: { candidate, viewer in
                await reads.append(candidate.id)
                return .init(viewer: viewer, pullRequest: candidate.pullRequest, isOpen: true)
            }, write: { await calls.append($0.id) }))
        await autopilot.waitUntilIdle()
        #expect(!autopilot.isActive && autopilot.queue.map(\.id) == ["batch-2"])
        #expect(await reads.values == ["batch-1"])
        #expect(await calls.values == ["batch-1"])
    }

    @Test("Entrar sólo muestra la cola, que se mantiene viva estando apagado")
    func preview() {
        let autopilot = PullRequestAutopilot()
        #expect(!autopilot.isPresented && !autopilot.isEnabled)
        autopilot.present(candidates([fixture(1), fixture(2, author: "alice"), fixture(3, author: "renovate")]), viewer: "me")
        #expect(autopilot.isPresented && autopilot.isExpanded && !autopilot.isEnabled)
        #expect(autopilot.queue.map(\.id) == ["batch-1"])
        autopilot.reconcile(candidates([fixture(4, mergeState: .clean), fixture(1, checks: .pending)]), viewer: "me")
        #expect(autopilot.queue.map(\.id) == ["batch-4"])
        #expect(autopilot.current == nil && autopilot.history.isEmpty)
        autopilot.close()
        #expect(!autopilot.isPresented && autopilot.queue.isEmpty)
    }

    @Test("Permanece encendido sin trabajo, recibe PRs nuevos y permite aprobar → mergear el mismo SHA")
    func continuous() async {
        let clock = AutopilotClock()
        let autopilot = PullRequestAutopilot(runner: clock.runner())
        let calls = AutopilotCalls()
        autopilot.enable([], viewer: "me", operations: operations(calls))
        #expect(autopilot.isEnabled && autopilot.current == nil)
        let review = candidates([fixture(1)])
        autopilot.reconcile(review, viewer: "me")
        await autopilot.waitUntilIdle()
        #expect(await calls.values == review.map(\.fingerprint))
        autopilot.reconcile(review, viewer: "me")
        await autopilot.waitUntilIdle()
        #expect(await calls.values.count == 1)
        let merge = candidates([fixture(1, mergeState: .clean)])
        autopilot.reconcile(merge, viewer: "me")
        await autopilot.waitUntilIdle()
        #expect(await calls.values == (review + merge).map(\.fingerprint))
        #expect(clock.date.timeIntervalSince1970 == 1)
        #expect(autopilot.isEnabled && autopilot.queue.isEmpty)
    }

    @Test("Refresh reemplaza pendientes, conserva la operación en curso y revalida antes de escribir")
    func refreshWhileReading() async {
        let autopilot = PullRequestAutopilot(runner: AutopilotClock().runner())
        let calls = AutopilotCalls()
        let gate = AutopilotGate()
        autopilot.enable(candidates([fixture(1), fixture(2)]), viewer: "me", operations: .init(
            read: { candidate, viewer in
                if candidate.id == "batch-1" { await gate.enter() }
                return .init(viewer: viewer, pullRequest: candidate.pullRequest, isOpen: true)
            }, write: { await calls.append($0.id) }))
        await gate.wait()
        autopilot.reconcile(candidates([fixture(3)]), viewer: "me")
        #expect(autopilot.current?.id == "batch-1")
        #expect(autopilot.queue.map(\.id) == ["batch-3"])
        await gate.release()
        await autopilot.waitUntilIdle()
        #expect(await calls.values == ["batch-3"])
        #expect(autopilot.history.count == 2)
    }

    @Test("Apagar deja terminar la escritura enviada, mantiene la cola visible y no repite éxitos")
    func stopDuringWrite() async {
        let autopilot = PullRequestAutopilot(runner: AutopilotClock().runner())
        let gate = AutopilotGate()
        let calls = AutopilotCalls()
        let prs = candidates([fixture(1), fixture(2)])
        autopilot.enable(prs, viewer: "me", operations: .init(
            read: { .init(viewer: $1, pullRequest: $0.pullRequest, isOpen: true) },
            write: { candidate in
                await calls.append(candidate.id)
                if candidate.id == "batch-1" { await gate.enter() }
            }))
        await gate.wait()
        autopilot.stop()
        autopilot.close()
        #expect(autopilot.isPresented && autopilot.current?.id == "batch-1")
        #expect(!autopilot.isEnabled && autopilot.queue.map(\.id) == ["batch-2"])
        await gate.release()
        await autopilot.waitUntilIdle()
        #expect(await calls.values == ["batch-1"])
        autopilot.enable(prs, viewer: "me", operations: operations(calls))
        await autopilot.waitUntilIdle()
        #expect(await calls.values == ["batch-1", prs[1].fingerprint])
    }

    @Test("Un error incierto detiene autopilot; refrescar o volver a encender no repite esa escritura")
    func uncertainFailure() async {
        let autopilot = PullRequestAutopilot(runner: AutopilotClock().runner())
        let calls = AutopilotCalls()
        let prs = candidates([fixture(1), fixture(2)])
        autopilot.enable(prs, viewer: "me", operations: .init(
            read: { .init(viewer: $1, pullRequest: $0.pullRequest, isOpen: true) },
            write: { candidate in
                await calls.append(candidate.fingerprint)
                throw GH.Failure.commandFailed(exitCode: 1, stderr: "Connection lost")
            }))
        await autopilot.waitUntilIdle()
        #expect(!autopilot.isEnabled && autopilot.notice != nil)
        #expect(autopilot.queue.map(\.id) == ["batch-2"])
        autopilot.reconcile(prs, viewer: "me")
        autopilot.enable(prs, viewer: "me", operations: operations(calls))
        await autopilot.waitUntilIdle()
        #expect(await calls.values == prs.map(\.fingerprint))
    }

    @Test("Cambio de cuenta detiene incluso durante una lectura y no escribe con otra identidad")
    func accountChanged() async {
        let autopilot = PullRequestAutopilot()
        let gate = AutopilotGate()
        let calls = AutopilotCalls()
        autopilot.enable(candidates([fixture(1)]), viewer: "me", operations: .init(
            read: { candidate, viewer in
                await gate.enter()
                return .init(viewer: viewer, pullRequest: candidate.pullRequest, isOpen: true)
            }, write: { await calls.append($0.id) }))
        await gate.wait()
        autopilot.reconcile(candidates([fixture(2)]), viewer: "someone-else")
        await gate.release()
        await autopilot.waitUntilIdle()
        #expect(!autopilot.isEnabled && autopilot.notice != nil && autopilot.queue.isEmpty)
        #expect(await calls.values.isEmpty)
    }

    @Test("Un omitido no gira en bucle; vuelve cuando la cola general lo vio dejar de estar listo")
    func deferredReadiness() async {
        let autopilot = PullRequestAutopilot(runner: AutopilotClock().runner())
        let calls = AutopilotCalls()
        let prs = candidates([fixture(1)])
        autopilot.enable(prs, viewer: "me", operations: .init(
            read: { _, viewer in .init(viewer: viewer, pullRequest: fixture(1, checks: .pending), isOpen: true) },
            write: { await calls.append($0.id) }))
        await autopilot.waitUntilIdle()
        #expect(autopilot.history.count == 1 && autopilot.queue.isEmpty)
        autopilot.reconcile(prs, viewer: "me")
        await autopilot.waitUntilIdle()
        #expect(autopilot.history.count == 1)
        autopilot.stop()
        autopilot.reconcile([], viewer: "me")
        autopilot.enable(prs, viewer: "me", operations: operations(calls))
        await autopilot.waitUntilIdle()
        #expect(await calls.values == prs.map(\.fingerprint))
    }

    @Test("Un omitido que sigue listo se reintenta tras la espera, que crece con cada omisión")
    func deferredRetriesWhileStillReady() async {
        // Caso real: mergear un hermano deja a los demás UNKNOWN unos segundos y
        // la lectura fresca los omite, pero nunca salen de la cola general.
        let clock = AutopilotClock()
        let autopilot = PullRequestAutopilot(runner: clock.runner(), now: { clock.date })
        let calls = AutopilotCalls()
        let reads = AutopilotCalls()
        let prs = candidates([fixture(1)])
        var ready = false
        autopilot.enable(prs, viewer: "me", operations: .init(
            read: { candidate, viewer in
                await reads.append(candidate.id)
                let pr = await MainActor.run { ready } ? candidate.pullRequest : fixture(1, checks: .pending)
                return .init(viewer: viewer, pullRequest: pr, isOpen: true)
            },
            write: { await calls.append($0.id) }))
        await autopilot.waitUntilIdle()
        #expect(await reads.values.count == 1 && autopilot.queue.isEmpty)

        func refresh(after seconds: TimeInterval) async {
            clock.date.addTimeInterval(seconds)
            autopilot.reconcile(prs, viewer: "me")
            await autopilot.waitUntilIdle()
        }
        await refresh(after: PullRequestAutopilot.retryDelay - 1)
        #expect(await reads.values.count == 1)
        await refresh(after: 1)
        #expect(await reads.values.count == 2)
        // La segunda omisión duplica la espera.
        await refresh(after: PullRequestAutopilot.retryDelay)
        #expect(await reads.values.count == 2)
        ready = true
        await refresh(after: PullRequestAutopilot.retryDelay)
        #expect(await calls.values == ["batch-1"])
    }

    @Test("Un rate limit agota tres intentos con espera compartida y detiene antes del siguiente PR")
    func rateLimitStops() async throws {
        let clock = AutopilotClock()
        let autopilot = PullRequestAutopilot(runner: clock.runner())
        let calls = AutopilotCalls()
        let response = try GitHubAPIResponse(Data("HTTP/2.0 429 Error\nRetry-After: 2\n\n{\"message\":\"secondary rate limit\"}".utf8))
        let error = GitHubAPIError(response: response, detail: "secondary rate limit")
        autopilot.enable(candidates([fixture(1), fixture(2)]), viewer: "me", operations: .init(
            read: { .init(viewer: $1, pullRequest: $0.pullRequest, isOpen: true) },
            write: { candidate in await calls.append(candidate.id); throw error }))
        await autopilot.waitUntilIdle()
        #expect(await calls.values == ["batch-1", "batch-1", "batch-1"])
        #expect(clock.date.timeIntervalSince1970 == 4)
        #expect(!autopilot.isEnabled && autopilot.queue.map(\.id) == ["batch-1", "batch-2"])
    }

    @Test("La lectura fresca también impide ejecutar autores que no sean Dependabot")
    func freshAuthorRestriction() async {
        let autopilot = PullRequestAutopilot()
        let calls = AutopilotCalls()
        autopilot.enable(candidates([fixture(1)]), viewer: "me", operations: .init(
            read: { _, viewer in .init(viewer: viewer, pullRequest: fixture(1, author: "alice"), isOpen: true) },
            write: { await calls.append($0.id) }))
        await autopilot.waitUntilIdle()
        #expect(await calls.values.isEmpty)
        #expect(!autopilot.isEnabled && autopilot.notice != nil)
    }

    @Test("El store abre el preview apagado y alterna con selección manual sin ejecutar acciones")
    func storePreview() {
        let store = ReviewQueueStore.preview(reviews: [fixture(1), fixture(2, author: "alice")], merges: [])
        store.toggleBatchSelection()
        store.batch.toggle("batch-1")
        store.toggleAutopilot()
        #expect(!store.batch.isSelecting && store.batch.selectedIDs.isEmpty)
        #expect(store.autopilot.isPresented && !store.autopilot.isEnabled)
        #expect(store.autopilot.queue.map(\.id) == ["batch-1"])
        store.toggleAutopilot()
        #expect(!store.autopilot.isPresented && !store.batch.isSelecting)
        store.toggleAutopilot()
        #expect(store.autopilot.isPresented && !store.autopilot.isEnabled)
        store.toggleBatchSelection()
        #expect(store.batch.isSelecting && !store.autopilot.isPresented)
        store.toggleBatchSelection()
        #expect(!store.batch.isSelecting && !store.autopilot.isPresented)
    }
}

@MainActor
private final class AutopilotClock {
    var date = Date(timeIntervalSince1970: 0)
    func runner() -> GitHubActionRunner { GitHubActionRunner(now: { self.date }, sleep: { self.date.addTimeInterval($0) }) }
}
private actor AutopilotCalls {
    var values: [String] = []
    func append(_ value: String) { values.append(value) }
}
private actor AutopilotGate {
    private var entered = false
    private var continuation: CheckedContinuation<Void, Never>?
    private var observer: CheckedContinuation<Void, Never>?
    func enter() async {
        entered = true
        observer?.resume(); observer = nil
        await withCheckedContinuation { continuation = $0 }
    }
    func wait() async { if !entered { await withCheckedContinuation { observer = $0 } } }
    func release() { continuation?.resume(); continuation = nil }
}
