import Foundation

struct PullRequestNotification: Sendable {
    enum Queue: String, CaseIterable, Sendable {
        case review
        case merge

        var title: String {
            switch self {
            case .review: "Nuevo PR para revisar"
            case .merge: "Nuevo PR para mergear"
            }
        }
    }

    let queue: Queue
    let pullRequest: PullRequest
}

/// Una notificación por PR que entra en cada sección, sin agrupar ni filtrar
/// nuevamente: recibe exactamente los PRs que muestra esa sección del panel.
enum PullRequestNotificationPolicy {
    static func entries(
        in current: [PullRequest],
        since previousIDs: Set<String>?,
        queue: PullRequestNotification.Queue
    ) -> [PullRequestNotification] {
        // La primera carga establece la base; el backlog no es una entrada nueva.
        guard var seen = previousIDs else { return [] }
        return current.compactMap { pullRequest in
            guard seen.insert(pullRequest.id).inserted else { return nil }
            return PullRequestNotification(queue: queue, pullRequest: pullRequest)
        }
    }
}
