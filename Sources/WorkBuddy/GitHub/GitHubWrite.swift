import Foundation

/// Merge method; rawValue is the gh pr merge flag.
/// Use GitHub's viewerDefaultMergeMethod rather than asking the user.
/// The original repositories allowed only SQUASH, matching their single web action.
enum MergeMethod: String, Codable, CaseIterable, Sendable {
    case squash
    case merge
    case rebase

    var title: String {
        switch self {
        case .squash: L10n.text(.mergeSquash)
        case .merge: L10n.text(.mergeCommit)
        case .rebase: L10n.text(.mergeRebase)
        }
    }

    /// Convert the GraphQL enum. Unknown values return nil,
    /// disabling merge rather than guessing a method.
    init?(graphQL value: String) {
        switch value {
        case "SQUASH": self = .squash
        case "MERGE": self = .merge
        case "REBASE": self = .rebase
        default: return nil
        }
    }
}

/// The app's GitHub writes. Arguments are fixed templates rather than
/// arbitrary gh invocations. Each call acts on one PR without batching.
enum GitHubWrite: Sendable {
    case approve(repository: String, number: Int)
    case approveCommit(repository: String, number: Int, commitID: String)
    case rebase(repository: String, number: Int)
    case dependabotRebase(repository: String, number: Int)
    case mergeCommit(repository: String, number: Int, commitID: String, method: MergeMethod)
    case merge(repository: String, number: Int, method: MergeMethod)

    var arguments: [String] {
        switch self {
        // Without --body, this is an approval without a comment.
        // gh pr review --approve records a review event for required-reviewer rules.
        case .approve(let repository, let number):
            ["pr", "review", String(number), "--repo", repository, "--approve"]

        // Bind the review to the displayed, verified commit.
        // A Dependabot update during the request cannot expand the approved revision.
        case .approveCommit(let repository, let number, let commitID):
            ["api", "repos/\(repository)/pulls/\(number)/reviews", "--method", "POST",
             "-f", "event=APPROVE", "-f", "commit_id=\(commitID)"]

        // GitHub rejects the merge if HEAD changed after revalidation.
        case .mergeCommit(let repository, let number, let commitID, let method):
            ["api", "repos/\(repository)/pulls/\(number)/merge", "--method", "PUT",
             "-f", "sha=\(commitID)", "-f", "merge_method=\(method.rawValue)"]

        // Update the branch while keeping the PR open. Without --rebase,
        // GitHub would create a merge commit instead.
        case .rebase(let repository, let number):
            ["pr", "update-branch", String(number), "--repo", repository, "--rebase"]

        // Dependabot interprets this comment as a command.
        // This is a remote write, not a local branch operation.
        case .dependabotRebase(let repository, let number):
            ["pr", "comment", String(number), "--repo", repository,
             "--body", "@dependabot rebase"]

        // Always specify the method; gh pr merge otherwise prompts interactively.
        // Do not use --auto: the original repositories disabled automatic merging.
        // GitHub evaluates merge eligibility server-side when processing the request.
        case .merge(let repository, let number, let method):
            ["pr", "merge", String(number), "--repo", repository, "--\(method.rawValue)"]
        }
    }

    var action: PullRequestAction {
        switch self {
        case .approve, .approveCommit: .approve
        case .rebase: .rebase
        case .dependabotRebase: .dependabotRebase
        case .merge, .mergeCommit: .merge
        }
    }

}
