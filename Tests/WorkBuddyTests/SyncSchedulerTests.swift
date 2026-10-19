import Foundation
import Testing

@testable import WorkBuddy

@Suite("Shared background synchronization")
@MainActor
struct SyncSchedulerTests {
    @Test("The production interval is five minutes")
    func productionInterval() {
        #expect(SyncScheduler.autoRefreshInterval == .seconds(300))
    }

    @Test("Load both services at startup without views or duplicate starts")
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

    @Test("Repeat both queries in the background and stop on cancellation")
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

    @Test("Immediate cancellation leaves no pending synchronization")
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
