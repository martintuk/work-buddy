import Foundation

/// Conserva la última sección observada, independientemente de que los envíos
/// estén habilitados. Una consulta fallida no debe actualizar esta base.
@MainActor
final class PullRequestNotificationTracker {
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // Conserva la base de review de versiones anteriores.
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
        // Reemplazar, no acumular: salir y volver a entrar debe notificar otra vez.
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
