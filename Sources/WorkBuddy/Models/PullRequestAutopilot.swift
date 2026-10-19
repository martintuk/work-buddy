import Foundation
import Observation

/// A live queue; only the active operation retains its snapshot.
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

    private(set) var viewer = ""
    private var latest: [Candidate] = []
    // Retain successes and uncertain failures for the app session.
    // A stale refresh or toggling the mode must not repeat a write.
    private var handled: Set<String> = []
    // Retry skipped items when a refresh still reports them ready, with increasing delays to avoid spinning while GitHub rejects them. After merging a sibling, GitHub may temporarily recalculate mergeability.
    private var deferred: [String: (until: Date, delay: TimeInterval)] = [:]
    static let retryDelay: TimeInterval = 60
    static let maxRetryDelay: TimeInterval = 15 * 60
    private var operations: Operations?
    private var task: Task<Void, Never>?
    private var stopTimer: Timer?
    private var stopDeadline: Date?
    var onActivity: (Entry) -> Void = { _ in }
    private let runner: GitHubActionRunner
    private let now: () -> Date
    private let calendar: Calendar
    private let scheduleTimer: (Timer) -> Void

    init(runner: GitHubActionRunner = .shared, now: @escaping () -> Date = { .now },
         calendar: Calendar = .autoupdatingCurrent,
         scheduleTimer: @escaping (Timer) -> Void = { RunLoop.main.add($0, forMode: .common) }) {
        self.runner = runner
        self.now = now
        self.calendar = calendar
        self.scheduleTimer = scheduleTimer
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
        scheduleMidnightStop()
        reconcile(candidates, viewer: viewer)
    }

    func pauseForScopeChange() {
        guard isActive else { return }
        notice = LocalizedMessage(L10n.text(.autopilotScopeChanged))
        stop()
    }

    func stop() {
        isEnabled = false
        stopTimer?.invalidate()
        stopTimer = nil
        stopDeadline = nil
        rebuildQueue()
    }

    private func scheduleMidnightStop() {
        guard let deadline = calendar.dateInterval(of: .day, for: now())?.end else {
            stop()
            return
        }
        stopDeadline = deadline
        let timer = Timer(fire: deadline, interval: 0, repeats: false) { [weak self] _ in
            // Registered on the main run loop, even while the panel is closed.
            MainActor.assumeIsolated { _ = self?.shouldStop() }
        }
        stopTimer = timer
        scheduleTimer(timer)
    }

    private func shouldStop() -> Bool {
        // Revalidate after reads and waits: the timer may still be pending when the Mac wakes after midnight.
        if isEnabled, let stopDeadline, now() >= stopDeadline { stop() }
        return !isEnabled
    }

    func reconcile(_ candidates: [Candidate], viewer: String) {
        guard isPresented else { return }
        _ = shouldStop()
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
        // Leaving the main queue clears the delay, allowing immediate processing on return.
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
        guard !shouldStop(), task == nil, !queue.isEmpty, let operations else { return }
        let read = operations.read
        let write = operations.write
        task = Task {
            while !shouldStop(), let candidate = queue.first {
                guard operations.reserve(candidate) else {
                    deferRetry(candidate.fingerprint)
                    rebuildQueue()
                    continue
                }
                current = Entry(candidate: candidate, status: .pending)
                if let current { onActivity(current) }
                rebuildQueue()
                var completed = false
                var submitted = false
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
                        shouldStop: { self.shouldStop() },
                        isAllowed: { _ in
                            operations.isAllowed(candidate) && self.latest.contains { $0.fingerprint == candidate.fingerprint }
                        },
                        progress: { progress in
                            if case .executing = progress { submitted = true } else { submitted = false }
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
                        case .alreadyApproved, .alreadyMerged:
                            completed = true
                            handled.insert(candidate.fingerprint)
                        case .closed: handled.insert(candidate.fingerprint)
                        case .stopped: break
                        default: deferRetry(candidate.fingerprint)
                        }
                        if reason == .accountChanged {
                            notice = LocalizedMessage(reason.text)
                            stop()
                        }
                    }
                } catch {
                    let uncertain = GitHubActionRunner.needsVerification(error, submitted: submitted)
                    if uncertain { handled.insert(candidate.fingerprint) }
                    let message = LocalizedMessage(error.localizedDescription)
                    setStatus(uncertain ? .uncertain(message) : .failed(message))
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

    /// Wait only for available work; continuous mode can remain enabled.
    func waitUntilIdle() async { await task?.value }
}
