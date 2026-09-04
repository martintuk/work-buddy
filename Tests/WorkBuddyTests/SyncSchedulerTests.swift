import Foundation
import Testing

@testable import WorkBuddy

@Suite("Sync compartida en background")
@MainActor
struct SyncSchedulerTests {
    @Test("El intervalo de producción es de cinco minutos")
    func productionInterval() {
        #expect(SyncScheduler.autoRefreshInterval == .seconds(300))
    }

    @Test("Carga ambos servicios al iniciar, sin vistas, y no duplica el arranque")
    func initialSync() {
        var githubRefreshes = 0
        var jiraRefreshes = 0
        let scheduler = SyncScheduler {
            githubRefreshes += 1
            jiraRefreshes += 1
        }
        defer { scheduler.stop() }

        #expect(githubRefreshes == 0)
        #expect(jiraRefreshes == 0)
        scheduler.start()
        scheduler.start()
        #expect(githubRefreshes == 1)
        #expect(jiraRefreshes == 1)
    }

    @Test("Repite ambas consultas en background y se detiene al cancelar")
    func periodicSync() async throws {
        var githubRefreshes = 0
        var jiraRefreshes = 0
        let scheduler = SyncScheduler(interval: .milliseconds(10)) {
            githubRefreshes += 1
            jiraRefreshes += 1
        }
        defer { scheduler.stop() }
        scheduler.start()

        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while jiraRefreshes < 3, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(jiraRefreshes >= 3)
        #expect(githubRefreshes == jiraRefreshes)

        scheduler.stop()
        let stoppedCount = jiraRefreshes
        try await Task.sleep(for: .milliseconds(30))
        #expect(jiraRefreshes == stoppedCount)
        #expect(githubRefreshes == stoppedCount)
    }

    @Test("Cancelar inmediatamente no deja una sync pendiente")
    func immediateStop() async throws {
        var refreshes = 0
        let scheduler = SyncScheduler(interval: .milliseconds(10)) {
            refreshes += 1
        }
        scheduler.start()
        scheduler.stop()
        try await Task.sleep(for: .milliseconds(30))
        #expect(refreshes == 1)
    }
}
