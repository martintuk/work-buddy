import Foundation
import Observation

/// Selección viva del panel y snapshot inmutable de la ejecución actual.
@MainActor
@Observable
final class PullRequestBatch {
    struct Candidate: Identifiable, Sendable {
        let pullRequest: PullRequest
        let action: PullRequestBatchAction
        var id: String { pullRequest.id }
        var fingerprint: String {
            [id, action.rawValue, pullRequest.headRefOID ?? "", pullRequest.baseRefName,
             action == .merge ? pullRequest.defaultMergeMethod?.rawValue ?? "" : ""].joined(separator: ":")
        }
    }
    enum Status {
        case pending, checking, executing(PullRequestBatchAction), completed(PullRequestBatchAction)
        case waiting(seconds: Int, attempt: Int), skipped(PullRequestActionSkipReason), failed(LocalizedMessage)
        var isComplete: Bool {
            switch self { case .completed, .skipped, .failed: true; default: false }
        }
        var text: String {
            switch self {
            case .pending: L10n.text(.batchPending)
            case .checking: L10n.text(.batchChecking)
            case .executing(let action): action.runningText
            case .completed(let action): action.completedText
            case .waiting(let seconds, let attempt): L10n.text(.batchRetryWaiting, String(seconds), String(attempt))
            case .skipped(let reason): reason.text
            case .failed(let message): message.text
            }
        }
    }
    struct Entry: Identifiable {
        let candidate: Candidate
        var status: Status = .pending
        var id: String { candidate.id }
        var pullRequest: PullRequest { candidate.pullRequest }
    }

    private(set) var isSelecting = false
    private(set) var isRunning = false
    private(set) var candidates: [Candidate] = []
    private(set) var selectedIDs: Set<String> = []
    private(set) var entries: [Entry] = []
    private(set) var stopRequested = false
    private(set) var viewer = ""
    private let runner: GitHubActionRunner

    init(runner: GitHubActionRunner = GitHubActionRunner()) { self.runner = runner }

    var completedCount: Int { entries.count { $0.status.isComplete } }
    var succeededCount: Int { entries.count { if case .completed = $0.status { true } else { false } } }
    var skippedCount: Int { entries.count { if case .skipped = $0.status { true } else { false } } }
    var failedCount: Int { entries.count { if case .failed = $0.status { true } else { false } } }
    var runningIDs: Set<String> { isRunning ? Set(entries.map(\.id)) : [] }

    /// Prioridad de merge, una sola acción y una sola selección por PR.
    static func candidates(reviews: [PullRequest], merges: [PullRequest]) -> [Candidate] {
        var seen: Set<String> = []
        return [(PullRequestBatchAction.merge, merges), (.approve, reviews)].flatMap { action, prs in
            prs.filter { action.isEligible($0) && seen.insert($0.id).inserted }
                .map { Candidate(pullRequest: $0, action: action) }
        }
    }

    func enter(_ candidates: [Candidate], viewer: String) {
        guard !isSelecting else { return }
        self.viewer = viewer
        isSelecting = true
        selectedIDs = []
        entries = []
        reconcile(candidates, viewer: viewer)
    }

    func exit() {
        guard !isRunning else { return }
        isSelecting = false
        selectedIDs = []
        candidates = []
        entries = []
    }

    /// Conserva elecciones sólo para la misma acción, commit, base y método.
    /// Los recién llegados se muestran sin seleccionar, aun durante una ejecución.
    func reconcile(_ updated: [Candidate], viewer: String) {
        guard isSelecting else { return }
        let previous = Dictionary(uniqueKeysWithValues: candidates.map { ($0.id, $0.fingerprint) })
        var seen: Set<String> = []
        candidates = updated.filter { $0.action.isEligible($0.pullRequest) && seen.insert($0.id).inserted }
        selectedIDs.formIntersection(Set(candidates.filter { previous[$0.id] == $0.fingerprint }.map(\.id)))
        if self.viewer.lowercased() != viewer.lowercased() {
            selectedIDs = []
            if isRunning { stopRequested = true } else { self.viewer = viewer }
        }
    }

    func toggle(_ id: String) {
        guard isSelecting, !isRunning, candidates.contains(where: { $0.id == id }) else { return }
        if !selectedIDs.insert(id).inserted { selectedIDs.remove(id) }
    }

    func selected(_ action: PullRequestBatchAction) -> [Candidate] {
        candidates.filter { $0.action == action && selectedIDs.contains($0.id) }
    }

    func status(for pr: PullRequest) -> Status? {
        entries.first { $0.id == pr.id && $0.pullRequest.headRefOID == pr.headRefOID }?.status
    }

    func stop() { if isRunning { stopRequested = true } }

    @discardableResult
    func start(
        _ action: PullRequestBatchAction,
        read: @escaping @Sendable (PullRequest, String) async throws -> PullRequestActionCheck.Snapshot,
        write: @escaping @Sendable (PullRequest) async throws -> Void,
        isAllowed: @escaping @MainActor (PullRequest) -> Bool,
        didComplete: @escaping @MainActor (PullRequest) -> Void = { _ in },
        didFinish: @escaping @MainActor () -> Void = {}
    ) -> Task<Void, Never>? {
        guard isSelecting, !isRunning else { return nil }
        let targets = selected(action)
        guard !targets.isEmpty else { return nil }
        entries = targets.map { Entry(candidate: $0) }
        selectedIDs.subtract(targets.map(\.id))
        stopRequested = false
        isRunning = true
        let expectedViewer = viewer
        return Task {
            var rateLimited = false
            for index in entries.indices {
                let original = entries[index].pullRequest
                if rateLimited {
                    entries[index].status = .skipped(.rateLimited)
                    continue
                }
                do {
                    let result = try await runner.perform(
                        original, viewer: expectedViewer, action: action, batch: true,
                        read: read, write: write, shouldStop: { self.stopRequested }, isAllowed: isAllowed,
                        progress: { progress in
                            switch progress {
                            case .checking: self.entries[index].status = .checking
                            case .executing: self.entries[index].status = .executing(action)
                            case .waiting(let seconds, let attempt):
                                self.entries[index].status = .waiting(seconds: seconds, attempt: attempt)
                            }
                        }
                    )
                    switch result {
                    case .completed:
                        entries[index].status = .completed(action)
                        didComplete(original)
                    case .skipped(let reason):
                        entries[index].status = .skipped(reason)
                        if reason == .accountChanged { stopRequested = true }
                    }
                } catch {
                    entries[index].status = .failed(LocalizedMessage(error.localizedDescription))
                    rateLimited = (error as? GitHubAPIError)?.isRateLimited == true
                }
            }
            isRunning = false
            didFinish()
        }
    }
}
