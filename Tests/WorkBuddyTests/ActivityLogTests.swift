import Foundation
import Testing
@testable import WorkBuddy

@Suite("Historial de actividad")
@MainActor
struct ActivityLogTests {
    @Test("Progreso y reintentos actualizan una entrada; repetir la acción crea otra")
    func identityAndUnread() throws {
        let log = ActivityLog()
        let first = log.record(.approve, on: fixture(1), status: .checking)
        log.update(first, status: .waiting(seconds: 2, attempt: 2))
        log.update(first, status: .running)
        log.update(first, status: .succeeded)
        #expect(log.entries.count == 1 && log.unreadIDs == [first])
        #expect(log.runningCount == 0)
        let second = log.record(.approve, on: fixture(1), status: .running)
        #expect(first != second && log.entries.map(\.id) == [second, first])
        #expect(log.runningCount == 1)
        log.setVisible(true)
        #expect(log.unreadIDs.isEmpty)
        log.setPanelVisible(false)
        log.update(second, status: .failed(LocalizedMessage("Connection lost")))
        #expect(log.unreadIDs == [second] && log.hasUnreadErrors)
        log.setPanelVisible(true)
        #expect(log.unreadIDs.isEmpty && !log.hasUnreadErrors)
        log.setVisible(false)
        let third = log.record(.rebase, on: fixture(1))
        #expect(log.unreadIDs == [third])
        #expect(try #require(log.entries.last).target == "org/api #1")
    }

    @Test("Limpiar conserva pendientes y permite que terminen después")
    func clearWhileRunning() {
        let log = ActivityLog()
        let running = log.record(.merge, on: fixture(1), status: .running)
        log.record(.approve, on: fixture(2))
        log.record(.approve, on: fixture(3), status: .skipped(LocalizedMessage("Stopped")))
        log.record(.approve, on: fixture(4), status: .failed(LocalizedMessage("Failed")))
        log.clearCompleted()
        #expect(log.entries.map(\.id) == [running] && log.unreadIDs == [running])
        log.update(running, status: .succeeded)
        #expect(log.runningCount == 0 && log.entries.count == 1)
        log.clearCompleted()
        #expect(log.entries.isEmpty && log.unreadIDs.isEmpty)
    }

    @Test("Un error tardío vuelve al historial aunque se haya limpiado la apertura exitosa")
    func lateFailure() {
        let log = ActivityLog()
        let id = log.record(title: LocalizedMessage("Agent"), target: "org/api #1", symbol: "terminal")
        log.clearCompleted()
        log.record(id: id, title: LocalizedMessage("Agent"), target: "org/api #1", symbol: "terminal",
                   status: .failed(LocalizedMessage("Launch failed")))
        #expect(log.entries.count == 1 && log.entries.first?.id == id)
        #expect(log.hasUnreadErrors)
    }

    @Test("Cada PR del lote registra su resultado y sobrevive a salir o ejecutar otro lote")
    func batchResults() async throws {
        let log = ActivityLog()
        let batch = PullRequestBatch(runner: runner())
        batch.onActivity = { log.record($0, source: .batch) }
        batch.prepare([fixture(1), fixture(2), fixture(3)], viewer: "me")
        let started = batch.start(.approve,
            read: { .init(viewer: $1, pullRequest: $0, isOpen: true) },
            write: { if $0.number == 2 { throw GH.Failure.noAttempts } },
            isAllowed: { $0.number != 3 })
        let task = try #require(started)
        #expect(log.entries.count == 3 && log.runningCount == 3)
        await task.value
        #expect(log.entries.allSatisfy { $0.source == .batch && $0.status.isComplete })
        #expect(log.entries.count { $0.status.isError } == 1)
        #expect(log.entries.count { if case .skipped = $0.status { true } else { false } } == 1)
        let previousIDs = Set(log.entries.map(\.id))
        batch.exit()
        #expect(log.entries.count == 3)
        batch.prepare([fixture(1)], viewer: "me")
        let restarted = batch.start(.approve,
            read: { .init(viewer: $1, pullRequest: $0, isOpen: true) },
            write: { _ in }, isAllowed: { _ in true })
        await (try #require(restarted)).value
        #expect(log.entries.count == 4)
        #expect(!previousIDs.contains(try #require(log.entries.first).id))
    }

    @Test("El historial de autopilot conserva aprobación y merge del mismo PR al cerrar")
    func autopilotResults() async throws {
        let log = ActivityLog()
        let autopilot = PullRequestAutopilot(runner: runner())
        autopilot.onActivity = { log.record($0, source: .autopilot) }
        let review = PullRequestBatch.candidates(reviews: [fixture(1)], merges: [])
        autopilot.enable(review, viewer: "me", operations: .init(
            read: { .init(viewer: $1, pullRequest: $0.pullRequest, isOpen: true) }, write: { _ in }))
        await autopilot.waitUntilIdle()
        let merge = PullRequestBatch.candidates(reviews: [], merges: [fixture(1, mergeState: .clean)])
        autopilot.reconcile(merge, viewer: "me")
        await autopilot.waitUntilIdle()
        autopilot.stop()
        autopilot.close()
        #expect(log.entries.count == 2 && Set(log.entries.map(\.id)).count == 2)
        #expect(log.entries.allSatisfy { $0.source == .autopilot && $0.status.isComplete })
        #expect(log.entries.map(\.symbol) == ["arrow.triangle.merge", "checkmark.circle"])
    }

    @Test("El store conecta los lotes al historial y registra errores al abrir el agente")
    func storeIntegration() async throws {
        let batch = PullRequestBatch(runner: runner())
        let store = ReviewQueueStore(batch: batch)
        batch.prepare([fixture(1)], viewer: "me")
        let started = batch.start(.approve,
            read: { .init(viewer: $1, pullRequest: $0, isOpen: true) },
            write: { _ in }, isAllowed: { _ in true })
        await (try #require(started)).value
        #expect(store.activity.entries.count == 1)
        #expect(store.activity.entries.first?.source == .batch)
        await store.openAgent(fixture(1), folder: URL(fileURLWithPath: "/nonexistent-work-buddy-test-folder"))
        #expect(store.activity.entries.count == 2)
        #expect(store.activity.entries.first?.status.isError == true)
        #expect(store.activity.entries.first?.source == .manual)
    }

    @Test("Los textos del historial siguen los cambios de idioma")
    func localizedHistory() throws {
        var language = AppLanguage.spanish
        let log = ActivityLog()
        let id = log.record(title: LocalizedMessage(L10n.text(.prApprove, language: language)),
                            target: "org/api #1", symbol: "checkmark.circle")
        #expect(log.entries.first?.title.text == "Aprobar")
        language = .english
        #expect(log.entries.first?.title.text == "Approve")
        log.update(id, status: .failed(LocalizedMessage(L10n.text(.activityOpenFailed, language: language))))
        #expect(log.entries.first?.status.text == "Could not open the link")
        language = .spanish
        #expect(log.entries.first?.status.text == "No se pudo abrir el enlace")
    }

    private func runner() -> GitHubActionRunner {
        let clock = ActivityClock()
        return GitHubActionRunner(now: { clock.date }, sleep: { clock.date.addTimeInterval($0) })
    }
}

@MainActor
private final class ActivityClock {
    var date = Date(timeIntervalSince1970: 0)
}
