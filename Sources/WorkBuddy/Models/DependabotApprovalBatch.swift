import Foundation
import Observation

/// Conserva selección, progreso y resultados aunque se cierre el popover.
@MainActor
@Observable
final class DependabotApprovalBatch {
    enum Phase { case selecting, running, finished }
    enum SkipReason: Equatable {
        case changed, notReady, alreadyApproved, closed, scopeChanged, accountChanged, stopped

        var text: String {
            switch self {
            case .changed: L10n.text(.batchChanged)
            case .notReady: L10n.text(.batchNotReady)
            case .alreadyApproved: L10n.text(.batchAlreadyApproved)
            case .closed: L10n.text(.batchClosed)
            case .scopeChanged: L10n.text(.batchScopeChanged)
            case .accountChanged: L10n.text(.batchAccountChanged)
            case .stopped: L10n.text(.batchStopped)
            }
        }
    }
    enum Status {
        case pending, checking, approving, approved, skipped(SkipReason), failed(LocalizedMessage)

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

    /// Un error de escritura conserva el resultado incierto y nunca reintenta.
    /// Detener permite terminar la request actual y omite el resto.
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
            for index in entries.indices {
                let original = entries[index].pullRequest
                if stopRequested {
                    entries[index].status = .skipped(.stopped)
                    continue
                }
                guard isAllowed(original) else {
                    entries[index].status = .skipped(.scopeChanged)
                    continue
                }
                do {
                    entries[index].status = .checking
                    let snapshot = try await read(original, viewer)
                    if stopRequested {
                        entries[index].status = .skipped(.stopped)
                        continue
                    }
                    guard isAllowed(original) else {
                        entries[index].status = .skipped(.scopeChanged)
                        continue
                    }
                    if let reason = Self.skipReason(for: original, snapshot: snapshot, viewer: viewer) {
                        entries[index].status = .skipped(reason)
                        if reason == .accountChanged { stopRequested = true }
                        continue
                    }
                    entries[index].status = .approving
                    try await approve(original)
                    entries[index].status = .approved
                    didApprove(original)
                } catch {
                    entries[index].status = .failed(LocalizedMessage(error.localizedDescription))
                }
            }
            phase = .finished
            didFinish()
        }
    }

    static func skipReason(
        for original: PullRequest, snapshot: DependabotApprovalCheck.Snapshot, viewer: String
    ) -> SkipReason? {
        guard snapshot.viewer.lowercased() == viewer.lowercased() else { return .accountChanged }
        guard snapshot.isOpen, let current = snapshot.pullRequest else { return .closed }
        guard current.id == original.id, current.repository == original.repository,
              current.number == original.number, current.headRefOID == original.headRefOID,
              original.headRefOID != nil else { return .changed }
        if current.approvedByMe { return .alreadyApproved }
        return current.canBatchApproveDependabot ? nil : .notReady
    }
}
