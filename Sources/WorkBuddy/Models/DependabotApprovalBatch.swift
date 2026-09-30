import Foundation
import Observation

/// Conserva selección, progreso y resultados aunque se cierre el popover.
@MainActor
@Observable
final class DependabotApprovalBatch {
    enum Phase { case selecting, running, finished }
    enum SkipReason: Equatable {
        case changed, notReady, alreadyApproved, closed, scopeChanged, accountChanged, stopped, rateLimited

        var text: String {
            switch self {
            case .changed: L10n.text(.batchChanged)
            case .notReady: L10n.text(.batchNotReady)
            case .alreadyApproved: L10n.text(.batchAlreadyApproved)
            case .closed: L10n.text(.batchClosed)
            case .scopeChanged: L10n.text(.batchScopeChanged)
            case .accountChanged: L10n.text(.batchAccountChanged)
            case .stopped: L10n.text(.batchStopped)
            case .rateLimited: L10n.text(.batchRateLimited)
            }
        }
    }
    enum Status {
        case pending, checking, approving, approved, skipped(SkipReason), failed(LocalizedMessage)

        case waiting(seconds: Int, attempt: Int)

        var isComplete: Bool {
            switch self {
            case .approved, .skipped, .failed: true
            default: false
            }
        }
        var text: String {
            switch self {
            case .pending: L10n.text(.batchPending)
            case .checking: L10n.text(.batchChecking)
            case .approving: L10n.text(.batchApproving)
            case .waiting(let seconds, let attempt): L10n.text(.batchRetryWaiting, String(seconds), String(attempt))
            case .approved: L10n.text(.batchApproved)
            case .skipped(let reason): reason.text
            case .failed(let error): error.text
            }
        }
    }
    struct Entry: Identifiable {
        let pullRequest: PullRequest
        var status: Status = .pending
        var id: String { pullRequest.id }
    }

    private(set) var entries: [Entry] = []
    private(set) var selectedIDs: Set<String> = []
    private(set) var phase: Phase = .selecting
    private(set) var stopRequested = false
    private(set) var viewer = ""
    var isPresented = false
    private let approvals: GitHubApproval

    init(approvals: GitHubApproval = GitHubApproval()) { self.approvals = approvals }

    var isRunning: Bool { phase == .running }
    var completedCount: Int { entries.count { $0.status.isComplete } }
    var approvedCount: Int { entries.count { if case .approved = $0.status { true } else { false } } }
    var skippedCount: Int { entries.count { if case .skipped = $0.status { true } else { false } } }
    var failedCount: Int { entries.count { if case .failed = $0.status { true } else { false } } }

    func prepare(_ candidates: [PullRequest], viewer: String) {
        guard !isRunning else { isPresented = true; return }
        entries = candidates.uniquedByID().filter(\.canBatchApproveDependabot).map { Entry(pullRequest: $0) }
        selectedIDs = Set(entries.map(\.id))
        self.viewer = viewer
        phase = .selecting
        stopRequested = false
        isPresented = true
    }

    func toggle(_ id: String) {
        guard phase == .selecting, entries.contains(where: { $0.id == id }) else { return }
        if !selectedIDs.insert(id).inserted { selectedIDs.remove(id) }
    }

    /// Sólo retira candidatos que dejaron de cumplir el criterio. Un refresh
    /// nunca incorpora PRs nuevos ni cambia el commit de la selección.
    func reconcile(_ candidates: [PullRequest]) {
        guard phase == .selecting else { return }
        let current = Dictionary(uniqueKeysWithValues: candidates.uniquedByID()
            .filter(\.canBatchApproveDependabot).map { ($0.id, $0) })
        entries.removeAll { current[$0.id]?.headRefOID != $0.pullRequest.headRefOID }
        selectedIDs.formIntersection(Set(entries.map(\.id)))
    }

    func toggleAll() {
        guard phase == .selecting else { return }
        selectedIDs = selectedIDs.count == entries.count ? [] : Set(entries.map(\.id))
    }

    func stop() { if isRunning { stopRequested = true } }

    /// Sólo reintenta rechazos explícitos por rate limit. Si persisten, omite
    /// el resto del lote. Detener deja terminar una escritura ya enviada.
    @discardableResult
    func start(
        read: @escaping @Sendable (PullRequest, String) async throws -> DependabotApprovalCheck.Snapshot,
        approve: @escaping @Sendable (PullRequest) async throws -> Void,
        isAllowed: @escaping @MainActor (PullRequest) -> Bool,
        didApprove: @escaping @MainActor (PullRequest) -> Void = { _ in },
        didFinish: @escaping @MainActor () -> Void = {}
    ) -> Task<Void, Never>? {
        guard phase == .selecting, !selectedIDs.isEmpty else { return nil }
        entries.removeAll { !selectedIDs.contains($0.id) }
        phase = .running
        return Task {
            var rateLimited = false
            for index in entries.indices {
                let original = entries[index].pullRequest
                if rateLimited {
                    entries[index].status = .skipped(.rateLimited)
                    continue
                }
                do {
                    let result = try await approvals.perform(
                        original, viewer: viewer, dependabotOnly: true,
                        read: read, approve: approve,
                        shouldStop: { self.stopRequested }, isAllowed: isAllowed,
                        progress: { progress in
                            switch progress {
                            case .checking: self.entries[index].status = .checking
                            case .approving: self.entries[index].status = .approving
                            case .waiting(let seconds, let attempt):
                                self.entries[index].status = .waiting(seconds: seconds, attempt: attempt)
                            }
                        }
                    )
                    switch result {
                    case .approved:
                        entries[index].status = .approved
                        didApprove(original)
                    case .skipped(let reason):
                        entries[index].status = .skipped(reason)
                        if reason == .accountChanged { stopRequested = true }
                    }
                } catch {
                    entries[index].status = .failed(LocalizedMessage(error.localizedDescription))
                    rateLimited = (error as? GitHubAPIError)?.isRateLimited == true
                }
            }
            phase = .finished
            didFinish()
        }
    }

    static func skipReason(
        for original: PullRequest, snapshot: DependabotApprovalCheck.Snapshot, viewer: String, dependabotOnly: Bool = true
    ) -> SkipReason? {
        guard snapshot.viewer.lowercased() == viewer.lowercased() else { return .accountChanged }
        guard snapshot.isOpen, let current = snapshot.pullRequest else { return .closed }
        guard current.id == original.id, current.repository == original.repository,
              current.number == original.number, current.headRefOID == original.headRefOID,
              original.headRefOID != nil else { return .changed }
        if current.approvedByMe { return .alreadyApproved }
        return (dependabotOnly ? current.canBatchApproveDependabot : current.canApprove) ? nil : .notReady
    }
}
