import Foundation
import Observation

/// Una cola viva; sólo la operación en curso conserva su snapshot.
@MainActor
@Observable
final class PullRequestAutopilot {
    typealias Candidate = PullRequestBatch.Candidate
    typealias Entry = PullRequestBatch.Entry
    struct Operations {
        let read: @Sendable (Candidate, String) async throws -> PullRequestActionCheck.Snapshot
        let write: @Sendable (Candidate) async throws -> Void
        var reserve: (Candidate) -> Bool = { _ in true }
        var isAllowed: (Candidate) -> Bool = { _ in true }
        var finished: (Candidate, Bool) -> Void = { _, _ in }
    }

    private(set) var isPresented = false
    private(set) var isEnabled = false
    private(set) var current: Entry?
    private(set) var queue: [Candidate] = []
    private(set) var history: [Entry] = []
    private(set) var notice: LocalizedMessage?
    var isExpanded = false
    var isActive: Bool { isEnabled || current != nil }

    private var viewer = ""
    private var latest: [Candidate] = []
    // Conservamos éxitos y errores inciertos durante toda la sesión de la app.
    // Un refresh atrasado o apagar/encender no debe repetir una escritura.
    private var handled: Set<String> = []
    // Un omitido se reintenta cuando un refresh lo sigue viendo listo, con
    // espera creciente para no girar en bucle si GitHub insiste en que no.
    // Sin esto quedaba afuera hasta reiniciar la app: tras mergear un hermano,
    // GitHub recalcula la mergeabilidad y la lectura fresca lo ve no listo.
    private var deferred: [String: (until: Date, delay: TimeInterval)] = [:]
    static let retryDelay: TimeInterval = 60
    static let maxRetryDelay: TimeInterval = 15 * 60
    private var operations: Operations?
    private var task: Task<Void, Never>?
    var onActivity: (Entry) -> Void = { _ in }
    private let runner: GitHubActionRunner
    private let now: () -> Date

    init(runner: GitHubActionRunner = .shared, now: @escaping () -> Date = { .now }) {
        self.runner = runner
        self.now = now
    }

    func present(_ candidates: [Candidate], viewer: String) {
        isPresented = true
        isExpanded = true
        reconcile(candidates, viewer: viewer)
    }

    func close() {
        guard !isActive else { return }
        isPresented = false
        queue = []
    }

    func enable(_ candidates: [Candidate], viewer: String, operations: Operations) {
        guard !isActive else { return }
        if self.viewer.lowercased() != viewer.lowercased() {
            handled = []; deferred = [:]; history = []
        }
        self.viewer = viewer
        isPresented = true
        self.operations = operations
        notice = nil
        isEnabled = true
        reconcile(candidates, viewer: viewer)
    }

    func stop() {
        isEnabled = false
        rebuildQueue()
    }

    func reconcile(_ candidates: [Candidate], viewer: String) {
        guard isPresented else { return }
        if self.viewer.lowercased() != viewer.lowercased() {
            if isActive {
                notice = LocalizedMessage(L10n.text(.batchAccountChanged))
                latest = []
                stop()
                return
            }
            self.viewer = viewer
            handled = []; deferred = [:]; history = []
        }
        var seen: Set<String> = []
        latest = candidates.filter {
            $0.pullRequest.author.isDependabot && $0.action.isEligible($0.pullRequest) && seen.insert($0.id).inserted
        }
        // Al salir de la cola general se olvida la espera: si vuelve, va directo.
        let fingerprints = Set(latest.map(\.fingerprint))
        deferred = deferred.filter { fingerprints.contains($0.key) }
        rebuildQueue()
        pump()
    }

    private func rebuildQueue() {
        queue = isPresented ? latest.filter {
            $0.id != current?.id && !handled.contains($0.fingerprint) && !isDeferred($0.fingerprint)
        } : []
    }

    private func isDeferred(_ fingerprint: String) -> Bool {
        deferred[fingerprint].map { $0.until > now() } ?? false
    }

    private func deferRetry(_ fingerprint: String) {
        let delay = deferred[fingerprint].map { min($0.delay * 2, Self.maxRetryDelay) } ?? Self.retryDelay
        deferred[fingerprint] = (now().addingTimeInterval(delay), delay)
    }

    private func setStatus(_ status: PullRequestBatch.Status) {
        current?.status = status
        if let current { onActivity(current) }
    }

    private func pump() {
        guard isEnabled, task == nil, !queue.isEmpty, let operations else { return }
        let read = operations.read
        let write = operations.write
        task = Task {
            while isEnabled, let candidate = queue.first {
                guard operations.reserve(candidate) else {
                    deferRetry(candidate.fingerprint)
                    rebuildQueue()
                    continue
                }
                current = Entry(candidate: candidate, status: .checking)
                if let current { onActivity(current) }
                rebuildQueue()
                var completed = false
                do {
                    let result = try await runner.perform(candidate.pullRequest, viewer: viewer,
                        action: candidate.action, batch: true,
                        read: { _, viewer in
                            let snapshot = try await read(candidate, viewer)
                            guard snapshot.pullRequest?.author.isDependabot != false else {
                                throw PullRequestActionSkipped(reason: .scopeChanged)
                            }
                            return snapshot
                        },
                        write: { _ in try await write(candidate) },
                        shouldStop: { !self.isEnabled },
                        isAllowed: { _ in
                            operations.isAllowed(candidate) && self.latest.contains { $0.fingerprint == candidate.fingerprint }
                        },
                        progress: { progress in
                            switch progress {
                            case .checking: self.setStatus(.checking)
                            case .executing: self.setStatus(.executing(candidate.action))
                            case .waiting(let seconds, let attempt): self.setStatus(.waiting(seconds: seconds, attempt: attempt))
                            }
                        })
                    switch result {
                    case .completed:
                        completed = true
                        handled.insert(candidate.fingerprint)
                        setStatus(.completed(candidate.action))
                    case .skipped(let reason):
                        setStatus(.skipped(reason))
                        switch reason {
                        case .alreadyApproved, .alreadyMerged, .closed: handled.insert(candidate.fingerprint)
                        case .stopped: break
                        default: deferRetry(candidate.fingerprint)
                        }
                        if reason == .accountChanged {
                            notice = LocalizedMessage(reason.text)
                            stop()
                        }
                    }
                } catch {
                    handled.insert(candidate.fingerprint)
                    setStatus(.failed(LocalizedMessage(error.localizedDescription)))
                    notice = LocalizedMessage(error.localizedDescription)
                    stop()
                }
                if let current { history.append(current) }
                if history.count > 100 { history.removeFirst(history.count - 100) }
                current = nil
                operations.finished(candidate, completed)
                rebuildQueue()
            }
            task = nil
        }
    }

    /// Espera sólo el trabajo disponible; no necesita apagar el modo continuo.
    func waitUntilIdle() async { await task?.value }
}
