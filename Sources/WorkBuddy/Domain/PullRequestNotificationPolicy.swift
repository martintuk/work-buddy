import Foundation

struct PullRequestNotification: Sendable {
    enum Queue: String, CaseIterable, Sendable {
        case review
        case merge

        var title: String {
            switch self {
            case .review: L10n.text(.notificationsNewReview)
            case .merge: L10n.text(.notificationsNewMerge)
            }
        }
    }

    let queue: Queue
    let pullRequest: PullRequest
}

/// One notification per PR entering a section, without grouping or refiltering.
/// Input is exactly the PR list displayed by that panel section.
enum PullRequestNotificationPolicy {
    static func entries(
        in current: [PullRequest],
        since previousIDs: Set<String>?,
        queue: PullRequestNotification.Queue
    ) -> [PullRequestNotification] {
        // The first load establishes a baseline; the backlog is not a new arrival.
        guard var seen = previousIDs else { return [] }
        return current.compactMap { pullRequest in
            guard seen.insert(pullRequest.id).inserted else { return nil }
            return PullRequestNotification(queue: queue, pullRequest: pullRequest)
        }
    }
}
