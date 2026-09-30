import Foundation

/// Efectos confirmados que una lectura anterior todavía no conoce. Cada refresh
/// conserva la revisión con la que empezó; una lectura posterior vuelve a ser
/// autoritativa, incluyendo approvals descartados o commits nuevos.
struct PullRequestActionEffects {
    private struct Effect {
        let revision: Int
        let action: PullRequestAction
        let head: String?
    }
    private(set) var revision = 0
    private var effects: [String: [PullRequestAction: Effect]] = [:]

    mutating func record(_ action: PullRequestAction, on pr: PullRequest) {
        revision += 1
        effects[pr.id, default: [:]][action] = Effect(revision: revision, action: action, head: pr.headRefOID)
    }

    func applying(to prs: [PullRequest], readRevision: Int) -> [PullRequest] {
        prs.compactMap { pr in
            guard let pending = effects[pr.id] else { return pr }
            if let merge = pending[.merge], merge.revision > readRevision { return nil }
            if let effect = pending[.approve], effect.revision > readRevision, pr.headRefOID == effect.head {
                var approved = pr
                approved.approvedByMe = true
                return approved
            }
            return pr
        }
    }

    func applying(to counts: [String: Int], readRevision: Int) -> [String: Int] {
        counts.filter { id, _ in
            !(effects[id]?.values.contains { $0.revision > readRevision && $0.action != .approve } ?? false)
        }
    }

    mutating func finishRefresh(startedAt revision: Int) {
        effects = effects.compactMapValues { pending in
            let remaining = pending.filter { $0.value.revision > revision }
            return remaining.isEmpty ? nil : remaining
        }
    }
}
