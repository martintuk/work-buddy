import Foundation
import Testing

@testable import WorkBuddy

/// Pin write arguments here: missing flags can hang the process, while extra flags can change the action promised by its label.
@Suite("GitHub writes")
struct GitHubWriteTests {
    @Test("Rebase updates the branch without merging or commenting on the PR")
    func nativeRebase() {
        let arguments = GitHubWrite.rebase(repository: "org/repo", number: 42).arguments
        #expect(arguments == ["pr", "update-branch", "42", "--repo", "org/repo", "--rebase"])
    }

    @Test("Rebase posts the Dependabot command")
    func rebaseComment() {
        let arguments = GitHubWrite.dependabotRebase(
            repository: "org/repo",
            number: 17
        ).arguments
        #expect(arguments == [
            "pr", "comment", "17", "--repo", "org/repo",
            "--body", "@dependabot rebase"
        ])
    }

    @Test("Approval sends no comment")
    func approvalWithoutComment() {
        // `--body` would add comment text to the approval. Without it, this is a clean approval that still counts as a review event for required-reviewer rules.
        let arguments = GitHubWrite.approve(repository: "org/repo", number: 42).arguments
        #expect(arguments == ["pr", "review", "42", "--repo", "org/repo", "--approve"])
        #expect(!arguments.contains("--body"))
    }

    @Test("Merge always specifies an explicit method", arguments: MergeMethod.allCases)
    func explicitMergeMethod(method: MergeMethod) {
        // Without a method flag, `gh pr merge` prompts interactively and hangs the subprocess.
        let arguments = GitHubWrite.merge(
            repository: "org/repo",
            number: 7,
            method: method
        ).arguments

        #expect(arguments == ["pr", "merge", "7", "--repo", "org/repo", "--\(method.rawValue)"])

        // One of the three method flags must always be present.
        let methodFlags = Set(MergeMethod.allCases.map { "--\($0.rawValue)" })
        #expect(!methodFlags.isDisjoint(with: arguments))
    }

    @Test("Merge does not use --auto")
    func noAutoMerge() {
        // Auto-merge may be disabled in repositories. The action promises an immediate merge and must not arm auto-merge with `--auto`.
        for method in MergeMethod.allCases {
            let arguments = GitHubWrite.merge(
                repository: "org/repo",
                number: 1,
                method: method
            ).arguments
            #expect(!arguments.contains("--auto"))
        }
    }

    @Test("Repository and number are separate arguments rather than interpolated text")
    func separateArguments() {
        // Each value gets its own argv element so unusual repository names cannot become extra flags.
        let arguments = GitHubWrite.merge(
            repository: "org/repo with spacess",
            number: 3,
            method: .squash
        ).arguments
        #expect(arguments.contains("org/repo with spacess"))
        #expect(arguments.count == 6)
    }
}

@Suite("Action availability")
struct ActionAvailabilityTests {
    @Test("Actions change when the same PR becomes ready and blocked again")
    func actionsDuringTransitions() {
        let id = "PR_239"
        let review = makePullRequest(id: id, defaultMergeMethod: .squash)
        let ready = makePullRequest(id: id, mergeable: .mergeable, mergeStateStatus: .clean)
        let blocked = makePullRequest(id: id, mergeable: .mergeable, mergeStateStatus: .blocked)

        #expect(!review.availableWriteActions(behindBy: nil).contains(.merge))
        #expect(ready.availableWriteActions(behindBy: nil).contains(.merge))
        #expect(!blocked.availableWriteActions(behindBy: nil).contains(.merge))
        #expect(!ready.availableWriteActions(behindBy: nil).contains(.rebase))
        #expect(ready.availableWriteActions(behindBy: 2).contains(.rebase))
        #expect(!ready.availableWriteActions(behindBy: 0).contains(.rebase))
    }

    @Test("Merge confirmation expires when the PR becomes blocked or disappears")
    func confirmationAgainstCurrentData() {
        let ready = makePullRequest(id: "PR_239", mergeable: .mergeable, mergeStateStatus: .clean)
        let pending = PendingPullRequestAction(action: .merge, pullRequest: ready)
        #expect(pending.isAvailable(for: ready, behindBy: nil))

        for state in [MergeStateStatus.blocked, .behind, .unknown, .dirty] {
            let updated = makePullRequest(id: ready.id, mergeable: .mergeable, mergeStateStatus: state)
            #expect(!pending.isAvailable(for: updated, behindBy: nil))
        }
        #expect(!pending.isAvailable(for: nil, behindBy: nil))
        #expect(!pending.isAvailable(for: makePullRequest(id: "another", mergeable: .mergeable,
                                                         mergeStateStatus: .clean), behindBy: nil))
    }

    @Test("Changing the merge method requires a new confirmation")
    func preserveConfirmedMethod() {
        let ready = makePullRequest(id: "PR_239", mergeable: .mergeable, mergeStateStatus: .clean)
        let pending = PendingPullRequestAction(action: .merge, pullRequest: ready)
        for method: MergeMethod? in [.merge, .rebase, nil] {
            let updated = makePullRequest(id: ready.id, mergeable: .mergeable,
                                          mergeStateStatus: .clean, defaultMergeMethod: method)
            #expect(!pending.isAvailable(for: updated, behindBy: nil))
        }
    }

    @Test("Rebase confirmation uses current branch lag", arguments: [false, true])
    func noRebaseWithStaleComparison(dependabot: Bool) {
        let pr = makePullRequest(author: Author(login: dependabot ? "dependabot" : "alice",
                                               typename: dependabot ? "Bot" : "User"))
        let pending = PendingPullRequestAction(action: dependabot ? .dependabotRebase : .rebase,
                                               pullRequest: pr)
        #expect(pending.isAvailable(for: pr, behindBy: 3))
        #expect(!pending.isAvailable(for: pr, behindBy: 0))
        #expect(!pending.isAvailable(for: pr, behindBy: nil))
    }

    @Test("Rebase requires measured lag and excludes only Dependabot")
    func rebaseAvailability() {
        for author in [
            Author(login: "human", typename: "User"),
            Author(login: "renovate", typename: "Bot"),
        ] {
            let pr = makePullRequest(author: author)
            #expect(pr.canRebase(behindBy: 1))
            #expect(!pr.canRebase(behindBy: 0))
            #expect(!pr.canRebase(behindBy: nil))
            #expect(!pr.canRebase(behindBy: -1))
        }
        for login in ["dependabot", "dependabot[bot]", "Dependabot"] {
            let pr = makePullRequest(author: Author(login: login, typename: "Bot"))
            #expect(!pr.canRebase(behindBy: 3))
        }
    }

    @Test("Approval is unavailable for the user's own PRs")
    func noSelfApproval() {
        // GitHub rejects this; offering an action that can only fail teaches users to ignore errors.
        #expect(!makePullRequest(authoredByMe: true).canApprove)
        #expect(makePullRequest(authoredByMe: false).canApprove)
    }

    @Test("Merge is unavailable without merge data")
    func noMergeWithoutData() {
        // The review query omits the expensive `mergeable` field. Without it, merging cannot be offered safely.
        #expect(!makePullRequest().isReadyToMerge)
    }

    @Test("GitHub determines the merge method")
    func methodFromGraphQL() {
        #expect(MergeMethod(graphQL: "SQUASH") == .squash)
        #expect(MergeMethod(graphQL: "MERGE") == .merge)
        #expect(MergeMethod(graphQL: "REBASE") == .rebase)
        // Do not guess new GitHub enum values: without a known method, merging is unavailable.
        #expect(MergeMethod(graphQL: "FAST_FORWARD") == nil)
        #expect(MergeMethod(graphQL: "squash") == nil)
    }

    @Test("Merge is unavailable without a known method")
    func unavailableWithoutMethod() {
        let ready = makePullRequest(mergeable: .mergeable, mergeStateStatus: .clean)
        #expect(ready.canMerge)

        let withoutMethod = makePullRequest(
            mergeable: .mergeable,
            mergeStateStatus: .clean,
            defaultMergeMethod: nil
        )
        #expect(withoutMethod.isReadyToMerge)
        #expect(!withoutMethod.canMerge)
    }

    @Test("Only actions writing to GitHub require confirmation")
    func actionsRequiringConfirmation() {
        #expect(PullRequestAction.dependabotRebase.needsConfirmation)
        #expect(PullRequestAction.merge.needsConfirmation)
        #expect(PullRequestAction.approve.needsConfirmation)
        #expect(PullRequestAction.rebase.needsConfirmation)
        #expect(!PullRequestAction.ignore.needsConfirmation)
        #expect(!PullRequestAction.restore.needsConfirmation)
        #expect(!PullRequestAction.open.needsConfirmation)
    }

    @Test("Both rebases, approval, and merge write to GitHub")
    func writeActions() {
        #expect(PullRequestAction.rebase.writesToGitHub)
        #expect(PullRequestAction.dependabotRebase.writesToGitHub)
        #expect(PullRequestAction.approve.writesToGitHub)
        #expect(PullRequestAction.merge.writesToGitHub)
        #expect(!PullRequestAction.open.writesToGitHub)
        #expect(!PullRequestAction.ignore.writesToGitHub)
        #expect(!PullRequestAction.restore.writesToGitHub)
    }

    @Test("Dependabot rebase is offered only when behind")
    func rebaseOnlyForBehindDependabot() {
        let dependabot = makePullRequest(
            author: Author(login: "dependabot", typename: "Bot")
        )
        #expect(dependabot.canRequestDependabotRebase(behindBy: 1))
        #expect(!dependabot.canRequestDependabotRebase(behindBy: 0))
        #expect(!dependabot.canRequestDependabotRebase(behindBy: nil))

        let otherBot = makePullRequest(author: Author(login: "renovate", typename: "Bot"))
        #expect(!otherBot.canRequestDependabotRebase(behindBy: 5))

        let human = makePullRequest(author: Author(login: "alice", typename: "User"))
        #expect(!human.canRequestDependabotRebase(behindBy: 5))

        let draft = makePullRequest(
            author: Author(login: "dependabot", typename: "Bot"),
            isDraft: true
        )
        #expect(!draft.canRequestDependabotRebase(behindBy: 5))
    }
}

// MARK: - Helper

private func makePullRequest(
    id: String = "PR_\(UUID().uuidString)",
    author: Author? = nil,
    authoredByMe: Bool = false,
    mergeable: MergeableState? = nil,
    mergeStateStatus: MergeStateStatus? = nil,
    defaultMergeMethod: MergeMethod? = .squash,
    isDraft: Bool = false
) -> PullRequest {
    PullRequest(
        id: id,
        number: 1,
        title: "a change",
        url: URL(string: "https://github.com/org/repo/pull/1")!,
        repository: "org/repo",
        baseRefName: "main",
        headRefName: "feature-branch",
        author: author ?? Author(login: authoredByMe ? "me" : "other", typename: "User"),
        updatedAt: .now,
        isDraft: isDraft,
        checks: .success,
        reviewDecision: .reviewRequired,
        mergeable: mergeable,
        mergeStateStatus: mergeStateStatus,
        defaultMergeMethod: defaultMergeMethod,
        authoredByMe: authoredByMe,
        requestedFromMe: true,
        reviewedByMe: false,
        approvals: 0, approvedByMe: false
    )
}
