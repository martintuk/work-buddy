import Foundation

/// Una cola compartida para aprobaciones individuales y por lote. Serializa
/// también las revalidaciones y conserva el cooldown entre operaciones.
@MainActor
final class GitHubApproval {
    static let shared = GitHubApproval()
    enum Result { case approved, skipped(DependabotApprovalBatch.SkipReason) }
    enum Progress { case checking, approving, waiting(seconds: Int, attempt: Int) }

    private let now: () -> Date
    private let sleep: (TimeInterval) async throws -> Void
    private var nextRequest = Date.distantPast
    private var busy = false
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Bool, Never>
    }
    private var waiters: [Waiter] = []

    init(now: @escaping () -> Date = { .now },
         sleep: @escaping (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }) {
        self.now = now
        self.sleep = sleep
    }

    func perform(
        _ original: PullRequest, viewer: String, dependabotOnly: Bool,
        read: @escaping @Sendable (PullRequest, String) async throws -> DependabotApprovalCheck.Snapshot,
        approve: @escaping @Sendable (PullRequest) async throws -> Void,
        shouldStop: @escaping () -> Bool = { false },
        isAllowed: @escaping (PullRequest) -> Bool = { _ in true },
        progress: @escaping (Progress) -> Void = { _ in }
    ) async throws -> Result {
        if shouldStop() { return .skipped(.stopped) }
        if !isAllowed(original) { return .skipped(.scopeChanged) }
        guard await acquire(shouldStop: shouldStop, isAllowed: { isAllowed(original) }) else {
            return .skipped(shouldStop() ? .stopped : .scopeChanged)
        }
        defer { release() }
        for attempt in 0..<3 {
            do {
                // Esperas cortas para que Detener responda durante el cooldown.
                while nextRequest > now() {
                    if shouldStop() { return .skipped(.stopped) }
                    if !isAllowed(original) { return .skipped(.scopeChanged) }
                    let remaining = nextRequest.timeIntervalSince(now())
                    progress(.waiting(seconds: Int(min(ceil(remaining), Double(Int32.max))), attempt: attempt + 1))
                    try await sleep(min(0.25, remaining))
                }
                try Task.checkCancellation()
                if shouldStop() { return .skipped(.stopped) }
                if !isAllowed(original) { return .skipped(.scopeChanged) }
                progress(.checking)
                let snapshot = try await read(original, viewer)
                if shouldStop() { return .skipped(.stopped) }
                if !isAllowed(original) { return .skipped(.scopeChanged) }
                if let reason = DependabotApprovalBatch.skipReason(
                    for: original, snapshot: snapshot, viewer: viewer, dependabotOnly: dependabotOnly
                ) {
                    // No repetimos una review que ya quedó registrada.
                    if attempt > 0, reason == .alreadyApproved { return .approved }
                    return .skipped(reason)
                }
                progress(.approving)
                do {
                    try await approve(original)
                } catch {
                    nextRequest = max(nextRequest, now().addingTimeInterval(1))
                    throw error
                }
                nextRequest = max(nextRequest, now().addingTimeInterval(1))
                return .approved
            } catch let error as GitHubAPIError where error.isRateLimited {
                nextRequest = max(nextRequest, now().addingTimeInterval(error.retryDelay(attempt: attempt, now: now())))
                guard attempt < 2 else { throw error }
                Diagnostics.record(.retry, metrics: [.attempt: attempt + 2], error: error)
            }
        }
        throw GH.Failure.noAttempts
    }

    private func acquire(shouldStop: @escaping () -> Bool, isAllowed: @escaping () -> Bool) async -> Bool {
        guard busy else { busy = true; return true }
        let id = UUID()
        // Una aprobación manual puede estar esperando a GitHub. Detener un
        // lote encolado no necesita esperar a que termine esa otra operación.
        let monitor = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                if shouldStop() || !isAllowed() {
                    if let index = waiters.firstIndex(where: { $0.id == id }) {
                        waiters.remove(at: index).continuation.resume(returning: false)
                    }
                    return
                }
            }
        }
        defer { monitor.cancel() }
        return await withCheckedContinuation { waiters.append(Waiter(id: id, continuation: $0)) }
    }

    private func release() {
        if waiters.isEmpty { busy = false } else { waiters.removeFirst().continuation.resume(returning: true) }
    }
}

struct ApprovalSkipped: LocalizedError {
    let reason: DependabotApprovalBatch.SkipReason
    var errorDescription: String? { reason.text }
}
