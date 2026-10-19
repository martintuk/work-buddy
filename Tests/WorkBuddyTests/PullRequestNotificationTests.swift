import Foundation
import Testing

@testable import WorkBuddy

@Suite("Entries into notifiable sections")
@MainActor
struct PullRequestNotificationTests {
    @Test("Each section has a silent initial load", arguments: PullRequestNotification.Queue.allCases)
    func firstLoad(queue: PullRequestNotification.Queue) {
        withDefaults { defaults in
            let tracker = PullRequestNotificationTracker(defaults: defaults)
            let pr = makePullRequest(1)
            #expect(tracker.process([pr], in: queue).isEmpty)
            #expect(tracker.process([pr], in: queue).isEmpty)
            #expect(tracker.process([pr, makePullRequest(2)], in: queue).map(\.pullRequest.number) == [2])
        }
    }

    @Test("More than three entries produce individual notifications with each PR link",
          arguments: PullRequestNotification.Queue.allCases)
    func noGrouping(queue: PullRequestNotification.Queue) {
        let prs = (1...10).map { makePullRequest($0) }
        let notifications = PullRequestNotificationPolicy.entries(in: prs, since: [], queue: queue)
        #expect(notifications.count == 10)
        #expect(notifications.map(\.pullRequest.url) == prs.map(\.url))
        #expect(notifications.allSatisfy { $0.queue == queue })
    }

    @Test("PRs moving from review to merge receive a merge notification")
    func transition() {
        withDefaults { defaults in
            let tracker = PullRequestNotificationTracker(defaults: defaults)
            let pr = makePullRequest(1)
            _ = tracker.process([], in: .review)
            _ = tracker.process([], in: .merge)
            #expect(tracker.process([pr], in: .review).count == 1)
            #expect(tracker.process([], in: .review).isEmpty)
            let notifications = tracker.process([pr], in: .merge)
            #expect(notifications.map(\.queue) == [.merge])
            #expect(notifications.map(\.pullRequest.id) == [pr.id])
            #expect(tracker.process([pr], in: .merge).isEmpty)
        }
    }

    @Test("Leaving and reentering notifies again, even after restarting",
          arguments: PullRequestNotification.Queue.allCases)
    func reentry(queue: PullRequestNotification.Queue) {
        withDefaults { defaults in
            let pr = makePullRequest(1)
            let tracker = PullRequestNotificationTracker(defaults: defaults)
            _ = tracker.process([pr], in: queue)
            let restarted = PullRequestNotificationTracker(defaults: defaults)
            #expect(restarted.process([pr], in: queue).isEmpty)
            #expect(restarted.process([], in: queue).isEmpty)
            #expect(restarted.process([pr], in: queue).count == 1)
        }
    }

    @Test("Merge-ready bots also notify without duplicates")
    func botsInMerge() {
        let bot = makePullRequest(1, bot: true)
        let visible = [bot, bot].readyToMerge
        let notifications = PullRequestNotificationPolicy.entries(in: visible, since: [], queue: .merge)
        #expect(notifications.map(\.pullRequest.id) == [bot.id])
    }

    @Test("Changing scope resets both baselines")
    func reset() {
        withDefaults { defaults in
            let tracker = PullRequestNotificationTracker(defaults: defaults)
            for queue in PullRequestNotification.Queue.allCases {
                _ = tracker.process([], in: queue)
            }
            tracker.resetBaseline()
            for queue in PullRequestNotification.Queue.allCases {
                #expect(tracker.process([makePullRequest(1)], in: queue).isEmpty)
            }
        }
    }

    @Test("Sections without successful queries keep their initial load pending")
    func independentLoads() {
        withDefaults { defaults in
            let tracker = PullRequestNotificationTracker(defaults: defaults)
            _ = tracker.process([], in: .review)
            #expect(tracker.process([makePullRequest(1)], in: .review).count == 1)
            #expect(tracker.process([makePullRequest(2)], in: .merge).isEmpty)
        }
    }

    @Test("Migration preserves the review baseline without affecting merge")
    func migration() {
        withDefaults { defaults in
            let pr = makePullRequest(1)
            defaults.set(true, forKey: "notifier.hasSeededBaseline")
            defaults.set([pr.id], forKey: "notifier.seenPullRequestIDs")
            let tracker = PullRequestNotificationTracker(defaults: defaults)
            #expect(tracker.process([pr, makePullRequest(2)], in: .review).map(\.pullRequest.number) == [2])
            #expect(tracker.process([pr], in: .merge).isEmpty)
            tracker.resetBaseline()
            let restarted = PullRequestNotificationTracker(defaults: defaults)
            #expect(restarted.process([makePullRequest(3)], in: .review).isEmpty)
        }
    }

    private func withDefaults(_ body: (UserDefaults) -> Void) {
        let name = "notification-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        body(defaults)
    }

    private func makePullRequest(_ number: Int, bot: Bool = false) -> PullRequest {
        PullRequest(
            id: "PR_\(number)", number: number, title: "Cambio \(number)",
            url: URL(string: "https://github.com/org/repo/pull/\(number)")!,
            repository: "org/repo", baseRefName: "main", headRefName: "change-\(number)",
            author: Author(login: bot ? "dependabot" : "alice", typename: bot ? "Bot" : "User"),
            updatedAt: .now, isDraft: false, checks: .success, reviewDecision: .reviewRequired,
            mergeable: .mergeable, mergeStateStatus: .clean, defaultMergeMethod: .squash,
            authoredByMe: false, requestedFromMe: true, reviewedByMe: false,
            approvals: 0, approvedByMe: false
        )
    }
}
