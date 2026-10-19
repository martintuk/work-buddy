import Foundation

/// Retain the last observed section regardless of whether delivery is enabled. Failed queries must not update this baseline.
@MainActor
final class PullRequestNotificationTracker {
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // Preserve the review baseline from earlier versions.
        if defaults.object(forKey: key(for: .review)) == nil,
           defaults.bool(forKey: "notifier.hasSeededBaseline") {
            defaults.set(
                defaults.stringArray(forKey: "notifier.seenPullRequestIDs") ?? [],
                forKey: key(for: .review)
            )
        }
        defaults.removeObject(forKey: "notifier.hasSeededBaseline")
        defaults.removeObject(forKey: "notifier.seenPullRequestIDs")
    }

    func process(
        _ current: [PullRequest],
        in queue: PullRequestNotification.Queue
    ) -> [PullRequestNotification] {
        let previousIDs = defaults.stringArray(forKey: key(for: queue)).map { Set($0) }
        let notifications = PullRequestNotificationPolicy.entries(
            in: current, since: previousIDs, queue: queue
        )
        // Replace rather than accumulate: leaving and reentering must notify again.
        defaults.set(Array(Set(current.map(\.id))), forKey: key(for: queue))
        return notifications
    }

    func resetBaseline() {
        for queue in PullRequestNotification.Queue.allCases {
            defaults.removeObject(forKey: key(for: queue))
        }
    }

    private func key(for queue: PullRequestNotification.Queue) -> String {
        "notifier.\(queue.rawValue).previousPullRequestIDs"
    }
}
