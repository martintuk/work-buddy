import Foundation
import Testing

@testable import WorkBuddy

/// Bucket classification previously failed against real data by filtering on CI status and by counting approvals manually. Both are regression cases here.
@Suite("PR classification")
struct ReviewBucketTests {
    @Test("Ownership-discovered Dependabot PRs are classified without requests or duplicates")
    func teamDependabotWithoutReviewRequest() {
        let pending = makePullRequest(authorLogin: "dependabot", authorTypename: "Bot", mergeable: .mergeable)
        let failed = makePullRequest(number: 2, checks: .failure, authorLogin: "dependabot", authorTypename: "Bot")
        let mergeable = makePullRequest(number: 3, reviewDecision: .approved,
                                       authorLogin: "dependabot", authorTypename: "Bot",
                                       mergeable: .mergeable, mergeStateStatus: .clean)
        let queue = [pending, pending, failed, mergeable].uniquedByID()
        let merges = [mergeable, mergeable].uniquedByID()
        let visible = queue.excludingMergeableAutomation(in: merges)
        #expect(visible.awaitingYourReview.map(\.id) == [pending.id])
        #expect(visible.automation.map(\.id) == [failed.id])
        #expect(merges.readyToMerge.map(\.id) == [mergeable.id])
        #expect(visible.excluding([pending.id]).awaitingYourReview.isEmpty)
    }

    // MARK: - Regressions observed against the live API

    @Test("Approvals GitHub rejects do not mark PRs as covered")
    func approvalsInsufficientWhenReviewRequired() {
        // An observed PR had three approvals and REVIEW_REQUIRED because a CODEOWNER review was missing. Counting approvals manually incorrectly classified it as covered.
        let pullRequest = makePullRequest(
            requestedFromMe: false,
            approvals: 3,
            reviewDecision: .reviewRequired
        )
        #expect(pullRequest.bucket() == .needsReview)
    }

    @Test("Failed CI never hides PRs awaiting personal review")
    func failedCIDoesNotChangeBucket() {
        // `statusCheckRollup` includes optional checks. Filtering on it hid 40 of 63 PRs, many still needing review.
        let pullRequest = makePullRequest(requestedFromMe: true, checks: .failure)
        #expect(pullRequest.bucket() == .needsReview)
    }

    // MARK: - Bucket priority

    @Test("Approved PRs are optional even when still requested")
    func approvalOverridesPersonalRequest() {
        let pullRequest = makePullRequest(
            requestedFromMe: true,
            reviewedByMe: false,
            approvals: 2,
            reviewDecision: .approved
        )
        #expect(pullRequest.bucket() == .approvedAlready)
    }

    @Test("Age does not change pending reviews or approved PRs",
          arguments: [1, 29, 30, 31, 40, 365])
    func ageDoesNotChangeAction(days: Int) {
        let updatedAt = Date.now.addingTimeInterval(-Double(days) * 24 * 60 * 60)
        let pending = makePullRequest(requestedFromMe: true, updatedAt: updatedAt)
        let approved = makePullRequest(reviewDecision: .approved, updatedAt: updatedAt)
        #expect(pending.bucket() == .needsReview)
        #expect(approved.bucket() == .approvedAlready)
        #expect([pending, approved].awaitingYourReview.map(\.id) == [pending.id])
    }

    @Test("Personal and team requests use the same rules",
          arguments: [false, true], [false, true])
    func equivalentRequests(requestedFromMe: Bool, reviewedByMe: Bool) {
        for decision: ReviewDecision? in [nil, .reviewRequired, .changesRequested, .approved] {
            let pr = makePullRequest(
                requestedFromMe: requestedFromMe,
                reviewedByMe: reviewedByMe,
                approvals: 3,
                reviewDecision: decision
            )
            #expect(pr.bucket() == (decision == .approved ? .approvedAlready : .needsReview))
            #expect([pr].awaitingYourReview.isEmpty == (decision == .approved))
        }
    }

    @Test("Personal approval excludes both categories even with active requests",
          arguments: [false, true], [false, true])
    func personallyApprovedNeedsNoReview(requestedFromMe: Bool, globallyApproved: Bool) {
        let pr = makePullRequest(
            requestedFromMe: requestedFromMe,
            reviewedByMe: true,
            approvedByMe: true,
            reviewDecision: globallyApproved ? .approved : .reviewRequired
        )
        #expect(pr.bucket() == nil)
        #expect([pr].reviewSections.isEmpty)
        #expect([pr].awaitingYourReview.isEmpty)
    }

    @Test("Others' approvals are not personal approval")
    func othersApprovalRemainsVisible() {
        let pr = makePullRequest(approvals: 2, reviewDecision: .approved)
        #expect([pr].reviewSections.map(\.bucket) == [.approvedAlready])
        #expect([pr].reviewSections.first?.items.map(\.id) == [pr.id])
    }

    // MARK: - Base cases

    @Test("Personal request without review belongs in review")
    func personalRequestWithoutReview() {
        #expect(makePullRequest(requestedFromMe: true).bucket() == .needsReview)
    }

    @Test("Earlier reviews do not create another category")
    func reviewedAndRequestedAgain() {
        let pullRequest = makePullRequest(requestedFromMe: true, reviewedByMe: true)
        #expect(pullRequest.bucket() == .needsReview)
    }

    @Test("Team-only requests belong in review")
    func teamRequest() {
        #expect(makePullRequest(requestedFromMe: false).bucket() == .needsReview)
    }

    @Test("Dependabot waits for successful CI and confirmed absence of conflicts",
          arguments: [CheckState.success, .failure, .error, .pending, .expected, .unknown],
          [MergeableState?.none, .mergeable, .conflicting, .unknown])
    func dependabotReadiness(checks: CheckState, mergeable: MergeableState?) {
        for draft in [false, true] {
            for decision: ReviewDecision in [.reviewRequired, .approved] {
                let pr = makePullRequest(reviewDecision: decision, checks: checks,
                                         authorLogin: "dependabot", authorTypename: "Bot",
                                         isDraft: draft, mergeable: mergeable)
                let ready = !draft && checks == .success && mergeable == .mergeable
                #expect(pr.bucket() == (ready ? (decision == .approved ? .approvedAlready : .needsReview) : nil))
                #expect([pr].awaitingYourReview.isEmpty == !(ready && decision == .reviewRequired))
                #expect([pr].automation.isEmpty == ready)
            }
        }
    }

    @Test("Ready Dependabot PRs retain personal approval and await other reviewers")
    func dependabotPersonalApproval() {
        let pr = makePullRequest(approvedByMe: true, reviewDecision: .reviewRequired,
                                 authorLogin: "dependabot[bot]", authorTypename: "Bot",
                                 mergeable: .mergeable)
        #expect(pr.bucket() == nil)
        #expect([pr].awaitingYourReview.isEmpty)
        #expect([pr].automation.map(\.id) == [pr.id])
    }

    @Test("Human PRs retain review with pending CI, conflicts, or draft state")
    func humanReadinessUnchanged() {
        let pr = makePullRequest(checks: .pending, isDraft: true, mergeable: .conflicting)
        #expect(pr.bucket() == .needsReview)
        #expect([pr].awaitingYourReview.map(\.id) == [pr.id])
        #expect([pr].automation.isEmpty)
    }
}

@Suite("Author classification")
struct AuthorTests {
    @Test("GitHub explicitly types bots")
    func typenameBot() {
        #expect(Author(login: "dependabot", typename: "Bot").isBot)
    }

    @Test("Machine accounts are typed as User")
    func machineAccount() {
        #expect(Author(
            login: "ci-service-user",
            typename: "User",
            machineAccounts: ["ci-service-user"]
        ).isBot)
    }

    @Test("People are not bots")
    func human() {
        #expect(!Author(login: "alice", typename: "User").isBot)
    }

    @Test("Missing typename falls back to configured machine accounts")
    func missingTypename() {
        #expect(!Author(login: "alice", typename: nil).isBot)
        #expect(Author(
            login: "ci-service-user",
            typename: nil,
            machineAccounts: ["ci-service-user"]
        ).isBot)
    }
}

@Suite("Queue grouping")
struct GroupingTests {
    @Test("Badges include automation without failures awaiting review")
    func badgeIncludesAutomation() {
        let queue = [
            makePullRequest(requestedFromMe: true, authorLogin: "alice"),
            makePullRequest(requestedFromMe: true, authorLogin: "dependabot", authorTypename: "Bot",
                            mergeable: .mergeable),
            makePullRequest(
                requestedFromMe: true,
                authorLogin: "ci-service-user",
                machineAccounts: ["ci-service-user"]
            ),
            makePullRequest(requestedFromMe: false, authorLogin: "bob")
        ]
        #expect(queue.awaitingYourReview.count == 4)
    }

    @Test(
        "Only sections awaiting personal action contribute to the badge",
        arguments: [
            (ReviewBucket.needsReview, true),
            (.approvedAlready, false) // tu review es opcional
        ]
    )
    func countedSections(bucket: ReviewBucket, counts: Bool) {
        #expect(bucket.needsYourReview == counts)
    }

    @Test("Pending reviews count even after earlier personal reviews")
    func previousReviewStillCounts() {
        let queue = [makePullRequest(requestedFromMe: true, reviewedByMe: true)]
        #expect(queue[0].bucket() == .needsReview)
        #expect(queue.awaitingYourReview.count == 1)
    }

    @Test("Automation is grouped by CI for bots and machine accounts",
          arguments: [CheckState.success, .failure, .error, .pending, .expected, .unknown], [false, true])
    func automationByCI(checks: CheckState, machine: Bool) {
        let bot = makePullRequest(checks: checks, authorLogin: "automation",
                                  authorTypename: machine ? "User" : "Bot",
                                  machineAccounts: machine ? ["automation"] : [])
        let human = makePullRequest(checks: checks)
        let queue = [human, bot]
        #expect(queue.reviewSections.count == 1)
        #expect(Set(queue.reviewSections[0].items.map(\.id)) ==
                (checks.isRed ? [human.id] : [human.id, bot.id]))
        #expect(Set(queue.awaitingYourReview.map(\.id)) ==
                Set(queue.reviewSections[0].items.map(\.id)))
        #expect(queue.automation.map(\.id) == (checks.isRed ? [bot.id] : []))
    }

    @Test("Automation respects personal and other approvals",
          arguments: [false, true], [false, true])
    func approvedAutomation(personal: Bool, global: Bool) {
        let bot = makePullRequest(approvedByMe: personal,
                                  reviewDecision: global ? .approved : .reviewRequired,
                                  authorTypename: "Bot")
        #expect([bot].reviewSections.map(\.bucket) ==
                (personal ? [] : [global ? .approvedAlready : .needsReview]))
        #expect([bot].awaitingYourReview.isEmpty == (personal || global))
        #expect([bot].automation.isEmpty == !(personal && !global))
    }

    @Test("Merge-ready bots are deduplicated even when review lacks mergeability",
          arguments: [CheckState.success, .failure])
    func mergePriority(checks: CheckState) {
        let bot = makePullRequest(checks: checks, authorTypename: "Bot",
                                  mergeable: .mergeable,
                                  mergeStateStatus: checks.isRed ? .unstable : .clean)
        let human = makePullRequest(authoredByMe: true, mergeable: .mergeable, mergeStateStatus: .clean)
        let data = [bot, human]
        #expect(data.readyToMerge.count == 2)
        // The review snapshot retains the ID but lacks merge fields.
        let reviewBot = PullRequest(
            id: bot.id, number: bot.number, title: bot.title, url: bot.url,
            repository: bot.repository, baseRefName: bot.baseRefName, headRefName: bot.headRefName,
            author: bot.author, updatedAt: bot.updatedAt, isDraft: false, checks: checks,
            reviewDecision: .reviewRequired, mergeable: nil, mergeStateStatus: nil,
            defaultMergeMethod: nil, authoredByMe: false, requestedFromMe: true,
            reviewedByMe: false, approvals: 0, approvedByMe: false
        )
        let visible = [reviewBot, human].excludingMergeableAutomation(in: data)
        #expect(visible.map(\.id) == [human.id])
        #expect(visible.automation.isEmpty)
        #expect(visible.awaitingYourReview.map(\.id) == [human.id])
        #expect([reviewBot].excludingMergeableAutomation(in: []).count == 1)
    }

    @Test("Failed automation retains favorites and recent activity")
    func automationFavorites() {
        let now = Date.now
        let recent = makePullRequest(number: 1, checks: .failure, updatedAt: now, authorTypename: "Bot")
        let old = makePullRequest(number: 2, checks: .error,
                                  updatedAt: now.addingTimeInterval(-3600), authorTypename: "Bot")
        let favorite = makePullRequest(number: 3, repository: "org/favorite", checks: .failure,
                                       updatedAt: now.addingTimeInterval(-7200), authorTypename: "Bot")
        var filter = RepositoryFilter()
        filter.toggleFavorite("org/favorite")
        let ordered = filter.prioritizingFavorites(in: [old, favorite, recent].automation)
        #expect(ordered.map(\.number) == [3, 1, 2])
    }

    @Test("Sections appear in priority order")
    func sectionOrder() {
        let queue = [
            makePullRequest(number: 1, reviewDecision: .approved),
            makePullRequest(number: 2, requestedFromMe: true),
            makePullRequest(number: 3, requestedFromMe: false)
        ]
        #expect(queue.reviewSections.map(\.bucket) == [.needsReview, .approvedAlready])
    }

    @Test("Newest activity comes first within sections")
    func orderWithinSection() {
        let older = makePullRequest(
            number: 1,
            requestedFromMe: true,
            updatedAt: .now.addingTimeInterval(-3600)
        )
        let newer = makePullRequest(number: 2, requestedFromMe: true)
        #expect([older, newer].reviewSections[0].items.map(\.number) == [2, 1])
    }
}

@Suite("Ignored PRs")
@MainActor
struct IgnoreListTests {
    /// Isolate defaults per test to avoid overwriting the running app's preferences.
    private func makeList() -> IgnoreList {
        let suite = UserDefaults(suiteName: "test-\(UUID().uuidString)")!
        return IgnoreList(defaults: suite)
    }

    @Test("Ignore and restore")
    func ignoreAndRestore() {
        let list = makeList()
        let pullRequest = makePullRequest()

        #expect(!list.contains(pullRequest))
        list.ignore(pullRequest)
        #expect(list.contains(pullRequest))
        list.restore(pullRequest)
        #expect(!list.contains(pullRequest))
    }

    @Test("IDs survive recreating the list")
    func persistence() {
        let suite = UserDefaults(suiteName: "test-\(UUID().uuidString)")!
        let pullRequest = makePullRequest()

        IgnoreList(defaults: suite).ignore(pullRequest)
        #expect(IgnoreList(defaults: suite).contains(pullRequest))
    }

    @Test("Badges exclude ignored PRs")
    func badgeExcludesHidden() {
        // The badge must not count hidden items or it would disagree with the visible panel.
        let visible = makePullRequest(number: 1, requestedFromMe: true, authorLogin: "alice")
        let hidden = makePullRequest(number: 2, requestedFromMe: true, authorLogin: "bob")
        let queue = [visible, hidden]

        #expect(queue.awaitingYourReview.count == 2)
        #expect(queue.excluding([hidden.id]).awaitingYourReview.count == 1)
    }

    @Test("Ignored items leave visible sections but remain listable")
    func partition() {
        let a = makePullRequest(number: 1, requestedFromMe: true)
        let b = makePullRequest(number: 2, requestedFromMe: true)
        let queue = [a, b]

        #expect(queue.excluding([b.id]).map(\.number) == [1])
        #expect(queue.only([b.id]).map(\.number) == [2])
    }
}

@Suite("Ready to merge")
struct ReadyToMergeTests {
    /// Observed queue states and expected verdicts: of 56 PRs, 45 were BLOCKED, four BEHIND, three DIRTY, three UNKNOWN, and one CLEAN.
    @Test(
        "The verdict comes from mergeStateStatus",
        arguments: [
            (MergeStateStatus.clean, true),
            (.unstable, true), // mergeable: an optional check failed
            (.hasHooks, true),
            (.blocked, false), // faltan reviews o checks requeridos
            (.behind, false), // must update against the base
            (.dirty, false), // conflictos
            (.draft, false),
            (.unknown, false) // GitHub has not calculated it yet
        ]
    )
    func verdictByState(state: MergeStateStatus, expected: Bool) {
        let pullRequest = makePullRequest(
            authoredByMe: true,
            mergeable: .mergeable,
            mergeStateStatus: state
        )
        #expect(pullRequest.isReadyToMerge == expected)
    }

    @Test("Conflicts prevent readiness even with CLEAN state")
    func conflictsOverrideState() {
        let pullRequest = makePullRequest(
            authoredByMe: true,
            mergeable: .conflicting,
            mergeStateStatus: .clean
        )
        #expect(!pullRequest.isReadyToMerge)
    }

    @Test("UNKNOWN mergeability is not ready because GitHub calculates it asynchronously")
    func unknownMergeability() {
        // Observed in about three of 56 PRs. Resolves on the next refresh; it is not an error.
        let pullRequest = makePullRequest(
            authoredByMe: true,
            mergeable: .unknown,
            mergeStateStatus: .clean
        )
        #expect(!pullRequest.isReadyToMerge)
    }

    @Test("Drafts are never ready")
    func draftNotReady() {
        let pullRequest = makePullRequest(
            authoredByMe: true,
            isDraft: true,
            mergeable: .mergeable,
            mergeStateStatus: .clean
        )
        #expect(!pullRequest.isReadyToMerge)
    }

    @Test("Missing merge data prevents readiness")
    func missingMergeData() {
        // The review query omits these expensive fields.
        #expect(!makePullRequest(authoredByMe: true).isReadyToMerge)
    }

    @Test("Personal approval does not disqualify a PR")
    func personalApprovalDoesNotDisqualify() {
        // Approving an automation PR removes the user's review request. It must not disappear just as it becomes mergeable.
        let pullRequest = makePullRequest(
            reviewedByMe: true,
            approvedByMe: true,
            reviewDecision: .approved,
            authorLogin: "ci-service-user",
            authorTypename: "User",
            machineAccounts: ["ci-service-user"],
            mergeable: .mergeable,
            mergeStateStatus: .clean
        )
        #expect(pullRequest.isReadyToMerge)
        #expect([pullRequest].readyToMerge.count == 1)
    }

    @Test("The section lists own and automation PRs, excluding others")
    func sectionScope() {
        let ready: (Int, String, Bool, String?, Set<String>) -> PullRequest = {
            number, login, mine, typename, machineAccounts in
            makePullRequest(
                number: number,
                authorLogin: login,
                authorTypename: typename,
                machineAccounts: machineAccounts,
                authoredByMe: mine,
                mergeable: .mergeable,
                mergeStateStatus: .clean
            )
        }
        let queue = [
            ready(1, "me", true, "User", []), // Own PR.
            ready(2, "dependabot", false, "Bot", []), // Automation.
            ready(3, "ci-service-user", false, "User", ["ci-service-user"]),
            ready(4, "alice", false, "User", []) // Another author's PR is outside the user's merge scope.
        ]
        // Compare as a set: updatedAt determines order and is identical here.
        #expect(Set(queue.readyToMerge.map(\.number)) == [1, 2, 3])
    }
}

@Suite("Needs fixes")
struct FixQueueTests {
    @Test("Only failed or errored CI needs fixes",
          arguments: [CheckState.success, .failure, .error, .pending, .expected, .unknown])
    func ciStates(checks: CheckState) {
        let pr = makePullRequest(checks: checks, authoredByMe: true)
        #expect([pr].needingCIFix.map(\.id) == (checks == .failure || checks == .error ? [pr.id] : []))
    }

    @Test("Exclude other authors, teams, and automation")
    func ownPRsOnly() {
        let mine = makePullRequest(checks: .failure, authoredByMe: true)
        let other = makePullRequest(requestedFromMe: true, checks: .failure)
        let team = makePullRequest(requestedFromMe: false, checks: .error)
        let bot = makePullRequest(checks: .failure, authorLogin: "dependabot", authorTypename: "Bot")
        let machine = makePullRequest(checks: .failure, authorLogin: "ci-bot",
                                      machineAccounts: ["ci-bot"], authoredByMe: true)
        #expect([mine, other, team, bot, machine].needingCIFix.map(\.id) == [mine.id])
    }

    @Test("No review requests, approvals, or merge readiness are required")
    func ownDraftWithFailure() {
        let pr = makePullRequest(requestedFromMe: false, reviewDecision: nil,
                                 checks: .failure, authoredByMe: true, isDraft: true)
        #expect([pr].needingCIFix.map(\.id) == [pr.id])
    }

    @Test("Optional CI failures appear even when merge is allowed")
    func mergeableWithFailure() {
        let pr = makePullRequest(reviewDecision: .approved, checks: .failure,
                                 authoredByMe: true, mergeable: .mergeable, mergeStateStatus: .unstable)
        #expect([pr].needingCIFix.map(\.id) == [pr.id])
        #expect([pr].readyToMerge.map(\.id) == [pr.id])
    }

    @Test("Respect ignored items, filters, and activity order")
    func filtersAndOrder() {
        let old = makePullRequest(number: 1, checks: .error,
                                  updatedAt: .now.addingTimeInterval(-3600), authoredByMe: true)
        let recent = makePullRequest(number: 2, checks: .failure, authoredByMe: true)
        let queue = [old, recent]
        #expect(queue.needingCIFix.map(\.id) == [recent.id, old.id])
        #expect(queue.excluding([recent.id]).needingCIFix.map(\.id) == [old.id])
        var filter = RepositoryFilter()
        filter.toggleMute(old.repository)
        #expect(filter.apply(to: queue).needingCIFix.isEmpty)
    }
}

@Suite("Needs rebase")
struct RebaseQueueTests {
    @Test("Own approved PRs with green CI and conflicts need rebase")
    func approvedWithConflicts() {
        let pr = makePullRequest(reviewDecision: .approved, checks: .success, authoredByMe: true,
                                 mergeable: .conflicting, mergeStateStatus: .dirty)
        #expect([pr].needingRebase.map(\.id) == [pr.id])
        #expect([pr].readyToMerge.isEmpty)
        #expect([pr].needingCIFix.isEmpty)
    }

    @Test("An approved own PR without conflicts but behind the required base needs a rebase")
    func approvedBehind() {
        let pr = makePullRequest(reviewDecision: .approved, checks: .success, authoredByMe: true,
                                 mergeable: .mergeable, mergeStateStatus: .behind)
        #expect([pr].needingRebase.map(\.id) == [pr.id])
        #expect([pr].readyToMerge.isEmpty)
    }

    @Test("Only confirmed conflicts count",
          arguments: [MergeableState.mergeable, .conflicting, .unknown])
    func mergeabilityStates(mergeable: MergeableState) {
        let pr = makePullRequest(authoredByMe: true, mergeable: mergeable)
        #expect([pr].needingRebase.map(\.id) == (mergeable == .conflicting ? [pr.id] : []))
    }

    @Test("Exclude non-green CI; failed CI belongs in fixes",
          arguments: [CheckState.failure, .error, .pending, .expected, .unknown])
    func greenCIOnly(checks: CheckState) {
        let pr = makePullRequest(checks: checks, authoredByMe: true, mergeable: .conflicting)
        #expect([pr].needingRebase.isEmpty)
        #expect([pr].needingCIFix.map(\.id) == (checks.isRed ? [pr.id] : []))
    }

    @Test("Exclude drafts, other authors, and automation")
    func ownPRsOnly() {
        let mine = makePullRequest(authoredByMe: true, mergeable: .conflicting)
        let draft = makePullRequest(authoredByMe: true, isDraft: true, mergeable: .conflicting)
        let other = makePullRequest(requestedFromMe: true, mergeable: .conflicting)
        let bot = makePullRequest(authorLogin: "dependabot", authorTypename: "Bot", mergeable: .conflicting)
        #expect([mine, draft, other, bot].needingRebase.map(\.id) == [mine.id])
    }
}

// MARK: - Helper

private func makePullRequest(
    number: Int = 1,
    repository: String = "org/repo",
    requestedFromMe: Bool = false,
    reviewedByMe: Bool = false,
    approvedByMe: Bool = false,
    approvals: Int = 0,
    reviewDecision: ReviewDecision? = .reviewRequired,
    checks: CheckState = .success,
    updatedAt: Date = .now,
    authorLogin: String = "alguien",
    authorTypename: String? = "User",
    machineAccounts: Set<String> = [],
    authoredByMe: Bool = false,
    isDraft: Bool = false,
    mergeable: MergeableState? = nil,
    mergeStateStatus: MergeStateStatus? = nil,
    defaultMergeMethod: MergeMethod? = .squash
) -> PullRequest {
    PullRequest(
        id: "PR_\(number)_\(UUID().uuidString)",
        number: number,
        title: "a change",
        url: URL(string: "https://github.com/\(repository)/pull/\(number)")!,
        repository: repository,
        baseRefName: "main",
        headRefName: "feature-branch",
        author: Author(
            login: authorLogin,
            typename: authorTypename,
            machineAccounts: machineAccounts
        ),
        updatedAt: updatedAt,
        isDraft: isDraft,
        checks: checks,
        reviewDecision: reviewDecision,
        mergeable: mergeable,
        mergeStateStatus: mergeStateStatus,
        defaultMergeMethod: defaultMergeMethod,
        authoredByMe: authoredByMe,
        requestedFromMe: requestedFromMe,
        reviewedByMe: reviewedByMe,
        approvals: approvals,
        approvedByMe: approvedByMe
    )
}
