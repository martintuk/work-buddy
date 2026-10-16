import Foundation

/// Aggregate CI checks for the latest commit.
enum CheckState: String, Codable, Sendable {
    case success = "SUCCESS"
    case failure = "FAILURE"
    case error = "ERROR"
    case pending = "PENDING"
    case expected = "EXPECTED"
    case unknown

    /// Include optional checks to classify automation and indicate failures,
    /// without deciding mergeability or hiding human review requests.
    var isRed: Bool { self == .failure || self == .error }
}

/// GitHub's aggregate review decision.
enum ReviewDecision: String, Codable, Sendable {
    case approved = "APPROVED"
    case changesRequested = "CHANGES_REQUESTED"
    case reviewRequired = "REVIEW_REQUIRED"
}

/// Whether the branch can merge without conflicts.
enum MergeableState: String, Codable, Sendable {
    case mergeable = "MERGEABLE"
    case conflicting = "CONFLICTING"
    /// GitHub computes this lazily. An initial UNKNOWN may resolve on the next
    /// request; observed in roughly three of 56 PRs.
    case unknown = "UNKNOWN"
}

/// GitHub's verdict on whether merging is currently enabled.
enum MergeStateStatus: String, Codable, Sendable {
    /// All requirements are satisfied.
    case clean = "CLEAN"
    /// Mergeable despite a failing optional check.
    case unstable = "UNSTABLE"
    /// Clean, with pre-receive hooks configured.
    case hasHooks = "HAS_HOOKS"
    /// Missing required reviews or checks; the most common measured queue state.
    case blocked = "BLOCKED"
    /// The branch must be updated against its base.
    case behind = "BEHIND"
    /// Merge conflicts.
    case dirty = "DIRTY"
    case draft = "DRAFT"
    case unknown = "UNKNOWN"
}

/// The PR author.
struct Author: Codable, Sendable {
    let login: String
    /// True when GitHub reports Bot or configuration lists this machine account.
    let isBot: Bool

    init(login: String, typename: String?, machineAccounts: Set<String> = []) {
        self.login = login
        isBot = typename == "Bot" || machineAccounts.contains(login.lowercased())
    }

    /// The @dependabot rebase command applies only to the Dependabot GitHub App,
    /// not every account classified as automation.
    var isDependabot: Bool {
        isBot && ["dependabot", "dependabot[bot]"].contains(login.lowercased())
    }
}

struct PullRequest: Codable, Identifiable, Sendable {
    let id: String
    let number: Int
    let title: String
    let url: URL
    let repository: String
    /// Target branch for merging.
    let baseRefName: String
    /// The PR's head branch.
    let headRefName: String
    let author: Author
    let updatedAt: Date
    let isDraft: Bool
    let checks: CheckState
    let reviewDecision: ReviewDecision?

    /// Dependabot requests mergeable to confirm no conflicts.
    /// mergeStateStatus also accounts for requirements that block merging.
    let mergeable: MergeableState?
    let mergeStateStatus: MergeStateStatus?

    /// GitHub's web default for this repository. If only squash is enabled,
    /// use that method here as GitHub does in the web interface.
    let defaultMergeMethod: MergeMethod?

    /// You opened this PR.
    let authoredByMe: Bool

    /// A direct request to you. Team requests have equal priority.
    let requestedFromMe: Bool
    /// You have reviewed this PR.
    let reviewedByMe: Bool
    let approvals: Int
    /// Your latest review decision is APPROVED and has not been dismissed.
    var approvedByMe: Bool
    /// Commit captured by the snapshot; batch actions retain this commit.
    var headRefOID: String? = nil
    /// Added and deleted lines, optional for decoding older saved snapshots.
    var additions: Int? = nil
    var deletions: Int? = nil

    /// Your review is complete, but GitHub still requires another approval.
    var awaitingOtherApproval: Bool {
        author.isBot && approvedByMe && reviewDecision == .reviewRequired
    }

    /// Prerequisites for reviewing Dependabot. Does not require other approvals
    /// that GitHub may need before merging.
    var isReadyForDependabotReview: Bool {
        !isDraft && checks == .success && mergeable == .mergeable
    }

    /// GitHub would currently enable merging. Use its verdict rather than
    /// reconstructing required reviews, checks, CODEOWNERS, or branch protection.
    /// UNSTABLE qualifies because it means an optional check failed; the row still
    /// shows that failure in its CI badge.
    var isReadyToMerge: Bool {
        guard !isDraft, mergeable == .mergeable else { return false }
        switch mergeStateStatus {
        case .clean, .unstable, .hasHooks:
            return true
        // BEHIND, BLOCKED, DIRTY, DRAFT, UNKNOWN, and nil are not ready.
        // UNKNOWN is not an error: GitHub may finish calculating it by the next refresh.
        default:
            return false
        }
    }

    /// GitHub forbids approving your own PR; do not offer an action that must fail.
    var canApprove: Bool { !authoredByMe && !approvedByMe }

    /// Require confirmed lag: a measured behind count, or GitHub's `BEHIND`
    /// verdict until the measurement arrives. A measurement, even zero, overrides
    /// the verdict. Other bots can use native rebase; only Dependabot is excluded.
    func canRebase(behindBy: Int?) -> Bool {
        guard !author.isDependabot else { return false }
        guard let behindBy else { return mergeStateStatus == .behind }
        return behindBy > 0
    }

    /// Offer the command only after comparison confirms the branch is behind.
    /// nil means unmeasured, not zero.
    func canRequestDependabotRebase(behindBy: Int?) -> Bool {
        author.isDependabot && !isDraft && (behindBy ?? 0) > 0
    }

    /// Offer merge only when GitHub confirms eligibility and supplies a known method.
    var canMerge: Bool { isReadyToMerge && defaultMergeMethod != nil }

    /// Repository name without the organization prefix, avoiding repetition in single-org lists.
    var shortRepository: String {
        repository.split(separator: "/").last.map(String.init) ?? repository
    }

    /// Classify a PR belonging to the review-request queue.
    func bucket() -> ReviewBucket? {
        PullRequestQueuePolicy.reviewBucket(for: self)
    }
}
