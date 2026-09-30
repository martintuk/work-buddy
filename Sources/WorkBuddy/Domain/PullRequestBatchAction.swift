import Foundation

/// La acción de un PR en selección múltiple sale de su categoría actual.
enum PullRequestBatchAction: String, CaseIterable, Sendable {
    case approve, merge

    var action: PullRequestAction { self == .approve ? .approve : .merge }
    var title: String { L10n.text(self == .approve ? .prApprove : .prMerge) }
    var symbol: String { self == .approve ? "checkmark.circle" : "arrow.triangle.merge" }
    var runningText: String { L10n.text(self == .approve ? .batchApproving : .batchMerging) }
    var completedText: String { L10n.text(self == .approve ? .batchApproved : .batchMerged) }
    func buttonTitle(_ count: Int) -> String {
        L10n.text(self == .approve ? .batchApproveCount : .batchMergeCount, String(count))
    }

    func isEligible(_ pr: PullRequest) -> Bool {
        guard pr.headRefOID != nil else { return false }
        switch self {
        case .approve:
            return pr.canApprove && !pr.approvedByMe && pr.bucket() == .needsReview
        case .merge:
            return (pr.authoredByMe || pr.author.isBot) && pr.canMerge
        }
    }

    func skipReason(for original: PullRequest, snapshot: PullRequestActionCheck.Snapshot,
                    viewer: String, batch: Bool) -> PullRequestActionSkipReason? {
        guard snapshot.viewer.lowercased() == viewer.lowercased() else { return .accountChanged }
        guard let current = snapshot.pullRequest else { return .closed }
        guard current.id == original.id, current.repository == original.repository,
              current.number == original.number, current.headRefOID == original.headRefOID,
              current.baseRefName == original.baseRefName, original.headRefOID != nil else { return .changed }
        if self == .merge, snapshot.isMerged { return .alreadyMerged }
        guard snapshot.isOpen else { return .closed }
        switch self {
        case .approve:
            if current.approvedByMe { return .alreadyApproved }
            return (batch ? isEligible(current) : current.canApprove) ? nil : .notReady
        case .merge:
            guard original.defaultMergeMethod != nil,
                  current.defaultMergeMethod == original.defaultMergeMethod else { return .methodChanged }
            return (batch ? isEligible(current) : current.canMerge) ? nil : .notReady
        }
    }
}

enum PullRequestActionSkipReason: Equatable {
    case changed, methodChanged, notReady, alreadyApproved, alreadyMerged, closed, scopeChanged, accountChanged, stopped, rateLimited

    var text: String {
        let key: L10n.Key = switch self {
        case .changed: .batchChanged
        case .methodChanged: .batchMethodChanged
        case .notReady: .batchNotReady
        case .alreadyApproved: .batchAlreadyApproved
        case .alreadyMerged: .batchAlreadyMerged
        case .closed: .batchClosed
        case .scopeChanged: .batchScopeChanged
        case .accountChanged: .batchAccountChanged
        case .stopped: .batchStopped
        case .rateLimited: .batchRateLimited
        }
        return L10n.text(key)
    }
}

struct PullRequestActionSkipped: LocalizedError {
    let reason: PullRequestActionSkipReason
    var errorDescription: String? { reason.text }
}
