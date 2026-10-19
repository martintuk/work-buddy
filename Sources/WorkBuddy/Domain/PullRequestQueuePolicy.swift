import Foundation

/// Review queue categories in priority order.
enum ReviewBucket: Int, CaseIterable, Sendable {
    case needsReview
    case approvedAlready

    var needsYourReview: Bool { self == .needsReview }
}

/// Pure business rules shared by panel, badge, and notifications.
/// Search determines scope: requests to you or your teams.
enum PullRequestQueuePolicy {
    /// Only GitHub's aggregate verdict confirms required approvals, including
    /// CODEOWNERS and branch protection; counting approvals is insufficient.
    /// Team requests count like direct requests. Age, CI, and prior comments do not
    /// change human review categories. Failing automation stays in its own section.
    /// Dependabot requires successful CI, confirmed absence of conflicts, and no draft flag.
    /// Your current approval removes a PR from both review categories even when others must approve.
    static func reviewBucket(for pullRequest: PullRequest) -> ReviewBucket? {
        guard !pullRequest.author.isBot || !pullRequest.checks.isRed else { return nil }
        if pullRequest.author.isDependabot && !pullRequest.isReadyForDependabotReview { return nil }
        guard !pullRequest.approvedByMe else { return nil }
        return pullRequest.reviewDecision == .approved ? .approvedAlready : .needsReview
    }
}

// MARK: - Grouping

/// Pure array transformations live outside the store so tests need no store instance or test seam.
extension [PullRequest] {
    func uniquedByID() -> [PullRequest] {
        var seen = Set<String>()
        return filter { seen.insert($0.id).inserted }
    }

    /// Exclude these IDs before grouping so ignored PRs are also excluded from the badge.
    func excluding(_ ids: Set<String>) -> [PullRequest] {
        filter { !ids.contains($0.id) }
    }

    /// Keep only PRs with these IDs.
    func only(_ ids: Set<String>) -> [PullRequest] {
        filter { ids.contains($0.id) }
    }

    /// Humans and automation grouped by pending review.
    /// Dependabot enters only when ready for review.
    var reviewSections: [(bucket: ReviewBucket, items: [PullRequest])] {
        let grouped = Dictionary(grouping: self) { $0.bucket() }
        return ReviewBucket.allCases.compactMap { bucket in
            guard let items = grouped[bucket], !items.isEmpty else { return nil }
            return (bucket, items.sorted { $0.updatedAt > $1.updatedAt })
        }
    }

    /// Bots with failed CI, Dependabot awaiting review prerequisites,
    /// or bots you approved that still require another approval.
    var automation: [PullRequest] {
        filter {
            $0.author.isBot && ($0.checks.isRed || $0.awaitingOtherApproval
                || ($0.author.isDependabot && !$0.isReadyForDependabotReview))
        }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    /// The review query lacks mergeability. Merge candidates identify bots
    /// whose action is already covered there and must not repeat in review or automation.
    func excludingMergeableAutomation(in mergeCandidates: [PullRequest]) -> [PullRequest] {
        excluding(Set(mergeCandidates.readyToMerge.filter(\.author.isBot).map(\.id)))
    }

    /// PRs GitHub allows you to merge within app scope: your own and automation PRs.
    /// Other people's PRs remain theirs to merge even when approved.
    var readyToMerge: [PullRequest] {
        filter { ($0.authoredByMe || $0.author.isBot) && $0.isReadyToMerge }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    /// Own PRs with failed CI, including drafts and optional checks.
    /// A PR can require a fix even when GitHub allows merging it.
    var needingCIFix: [PullRequest] {
        filter { $0.authoredByMe && !$0.author.isBot && $0.checks.isRed }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    /// Own PRs with conflicts and successful CI cannot be updated automatically.
    /// Failed CI belongs in To fix; drafts are not waiting for merge.
    var needingRebase: [PullRequest] {
        filter {
            $0.authoredByMe && !$0.author.isBot && !$0.isDraft
                && $0.checks == .success && $0.mergeable == .conflicting
        }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    /// Exactly the PRs shown under To review count toward the badge and notify.
    var awaitingYourReview: [PullRequest] {
        filter { $0.bucket()?.needsYourReview == true }
    }
}
