import Foundation

/// Un único ciclo para GitHub y Jira, independiente de las vistas del panel.
@MainActor
final class SyncScheduler {
    static let autoRefreshInterval: Duration = .seconds(300)

    private let interval: Duration
    private let refresh: @MainActor () -> Void
    private var task: Task<Void, Never>?

    init(
        interval: Duration = SyncScheduler.autoRefreshInterval,
        refresh: @escaping @MainActor () -> Void
    ) {
        self.interval = interval
        self.refresh = refresh
    }

    deinit { task?.cancel() }

    func start() {
        guard task == nil else { return }
        refresh()

        // Cada store inicia su consulta sin esperar al otro y evita solapamientos.
        task = Task { [interval, refresh] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: interval)
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                refresh()
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }
}
