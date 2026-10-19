import AppKit
import Foundation

/// Review queue state consumed by the panel.
@MainActor
@Observable
final class ReviewQueueStore {
    enum State {
        case idle
        case loading
        case loaded
        case failed(LocalizedMessage)
    }

    /// Opening the panel triggers a refresh after this interval.
    private static let staleAfter: TimeInterval = 120

    private(set) var state: State = .idle
    private(set) var configuration = AppConfiguration.load()
    private(set) var repositoryFilter = RepositoryFilter.load()
    private(set) var automationFilter = AutomationFilter.load()
    let localRepositories = LocalRepositoryStore()
    let editor = EditorStore()
    let agentCLI = AgentCLIStore()
    let projectOpener = ProjectOpener()
    let batch: PullRequestBatch
    let autopilot = PullRequestAutopilot()

    let activity: ActivityLog

    init(batch: PullRequestBatch = PullRequestBatch(runner: .shared),
         activity: ActivityLog = ActivityLog(storageURL: ActivityLog.defaultStorageURL)) {
        self.batch = batch
        self.activity = activity
        batch.onActivity = { [activity, weak batch] in activity.record($0, source: .batch, viewer: batch?.viewer) }
        autopilot.onActivity = { [activity, weak autopilot] in activity.record($0, source: .autopilot, viewer: autopilot?.viewer) }
    }
    private(set) var viewerLogin: String?
    private(set) var pullRequests: [PullRequest] = []
    /// Dependabot PRs in the review queue, grouped by CI status. Merge-ready items arrive through `mergeCandidates`.
    private(set) var dependabotPullRequests: [PullRequest] = []
    /// Merge candidates use a separate query because calculating mergeability for the entire review queue is expensive.
    private var requestedMergeCandidates: [PullRequest] = []
    private var teamDependabotPullRequests: [PullRequest] = []
    var mergeCandidates: [PullRequest] {
        (requestedMergeCandidates + teamDependabotPullRequests).uniquedByID()
    }
    private(set) var teamDependabotFailure: LocalizedMessage?
    private(set) var isLoadingTeamDependabot = false
    private var forceTeamDiscovery = false

    func retryTeamDependabot() {
        forceTeamDiscovery = true
        refresh(force: true)
    }
    /// The user's own PRs are queried separately, even when they need no review and cannot be merged.
    private(set) var fixCandidates: [PullRequest] = []
    private(set) var replyCandidates: [PullRequest] = []
    private(set) var waitingReplyCandidates: [PullRequest] = []
    private(set) var lastUpdated: Date?

    /// `behindBy` by PR ID. A missing ID means unmeasured, distinct from zero (up to date); confusing these would make rebasing a guess.
    private(set) var behindCounts: [String: Int] = [:]

    /// IDs of PRs with writes in progress.
    private(set) var inFlightActions: Set<String> = []

    /// The AppKit menu bar does not participate in SwiftUI observation, so this callback tells it when to redraw the badge.
    var onChange: (() -> Void)?

    let notifier = Notifier()
    private let notificationTracker = PullRequestNotificationTracker()
    private let ignoreList = IgnoreList()
    private var inFlight: Task<Void, Never>?
    /// Includes branch measurements that continue after queues are published.
    var isRefreshing: Bool { inFlight != nil }
    /// An action during a query requires another read after completion.
    private var hasPendingRefresh = false
    /// Invalidate results from queries started with a different configuration.
    private var configurationRevision = 0
    private var actionEffects = PullRequestActionEffects()

    // MARK: - Data views
    //
    // The logic lives in Domain/PullRequestQueuePolicy.swift and can be tested without instantiating the store.

    /// The complete queue, including Dependabot PRs discovered through ownership. Deduplicate by ID because these may overlap with review requests.
    private var reviewQueue: [PullRequest] {
        (pullRequests + dependabotPullRequests + teamDependabotPullRequests).uniquedByID()
    }

    /// All visible data comes from here: filter ignored items once so the badge cannot count items missing from the panel.
    private var visible: [PullRequest] {
        filtered(reviewQueue).excluding(ignoreList.ids)
            .excludingMergeableAutomation(in: mergeCandidates)
    }

    var repositories: [RepositoryFilter.Repository] {
        repositoryFilter.repositories(in: allKnown, including: localRepositories.repositories)
    }

    var hasActiveFilters: Bool {
        repositoryFilter.isActive || automationFilter.isActive
    }

    var hasFilteredResults: Bool {
        allKnown.contains { !repositoryFilter.includes($0.repository) || !automationFilter.includes($0) }
    }

    private func filtered(_ pullRequests: [PullRequest]) -> [PullRequest] {
        automationFilter.apply(to: repositoryFilter.apply(to: pullRequests))
    }

    var reviewSections: [(bucket: ReviewBucket, items: [PullRequest])] {
        visible.reviewSections.map { section in
            (section.bucket, repositoryFilter.prioritizingFavorites(in: section.items))
        }
    }

    var automation: [PullRequest] {
        repositoryFilter.prioritizingFavorites(in: visible.automation)
    }

    var awaitingYourReview: [PullRequest] { visible.awaitingYourReview }

    var batchCandidates: [PullRequestBatch.Candidate] {
        PullRequestBatch.candidates(reviews: reviewSections.first { $0.bucket == .needsReview }?.items ?? [], merges: readyToMerge)
            .filter { !activity.needsVerification(for: $0.pullRequest, viewer: viewerLogin) }
            .filter { !inFlightActions.contains($0.id) || batch.runningIDs.contains($0.id) || autopilot.current?.id == $0.id }
    }

    func toggleBatchSelection() {
        guard !autopilot.isActive, !batch.isRunning else { return }
        autopilot.close()
        if batch.isSelecting { batch.exit() }
        else if let viewerLogin { batch.enter(batchCandidates, viewer: viewerLogin) }
    }

    func reconcileBatch() {
        batch.reconcile(batchCandidates, viewer: viewerLogin ?? "")
        autopilot.reconcile(batchCandidates, viewer: viewerLogin ?? "")
    }

    func startBatch(_ action: PullRequestBatchAction) {
        reconcileBatch()
        guard !autopilot.isActive, !batch.isRunning, let viewerLogin, batch.viewer == viewerLogin else { return }
        let ids = Set(batch.selected(action).map(\.id))
        guard !ids.isEmpty, ids.isDisjoint(with: inFlightActions) else { return }
        let revision = configurationRevision
        let machineAccounts = configuration.machineAccounts
        inFlightActions.formUnion(ids)
        let task = batch.start(action,
            read: { try await PullRequestActionCheck.fetch($0, viewer: $1, action: action, machineAccounts: machineAccounts) },
            write: { try await GitHubActionRunner.submit($0, action: action) },
            isAllowed: { [self] pr in
                revision == configurationRevision
                    && filtered(allKnown).excluding(ignoreList.ids).contains { $0.id == pr.id }
            },
            didComplete: { [self] pr in
                if revision == configurationRevision, self.viewerLogin?.lowercased() == viewerLogin.lowercased() { applyCompletedAction(action.action, on: pr) }
                onChange?()
            },
            didFinish: { [self] in
                inFlightActions.subtract(ids)
                reconcileBatch()
                onChange?()
                refresh(force: true)
            }
        )
        if task == nil { inFlightActions.subtract(ids) }
        onChange?()
    }

    func toggleAutopilot() {
        guard !batch.isRunning, !autopilot.isActive else { return }
        if autopilot.isPresented {
            autopilot.close()
        } else if let viewerLogin {
            batch.exit()
            autopilot.present(batchCandidates, viewer: viewerLogin)
        }
    }

    func setAutopilotEnabled(_ enabled: Bool) {
        guard enabled else { autopilot.stop(); return }
        guard !batch.isRunning, let viewerLogin else { return }
        batch.exit()
        let revision = configurationRevision
        let machineAccounts = configuration.machineAccounts
        autopilot.enable(batchCandidates, viewer: viewerLogin, operations: .init(
            read: { candidate, viewer in
                try await PullRequestActionCheck.fetch(candidate.pullRequest, viewer: viewer,
                    action: candidate.action, machineAccounts: machineAccounts)
            },
            write: { try await GitHubActionRunner.submit($0.pullRequest, action: $0.action) },
            reserve: { [self] candidate in inFlightActions.insert(candidate.id).inserted },
            isAllowed: { [self] candidate in
                revision == configurationRevision && batchCandidates.contains { $0.fingerprint == candidate.fingerprint }
            },
            finished: { [self] candidate, completed in
                inFlightActions.remove(candidate.id)
                if revision == configurationRevision, self.viewerLogin?.lowercased() == viewerLogin.lowercased() {
                    if completed { applyCompletedAction(candidate.action.action, on: candidate.pullRequest) }
                    reconcileBatch()
                    refresh(force: true)
                }
                onChange?()
            }
        ))
    }

    /// Apply the same visible effect for manual actions, batches, and Autopilot.
    func applyCompletedAction(_ action: PullRequestAction, on pr: PullRequest) {
        let previousRevision = actionEffects.revision
        actionEffects.record(action, on: pr)
        pullRequests = actionEffects.applying(to: pullRequests, readRevision: previousRevision)
        dependabotPullRequests = actionEffects.applying(to: dependabotPullRequests, readRevision: previousRevision)
        teamDependabotPullRequests = actionEffects.applying(to: teamDependabotPullRequests, readRevision: previousRevision)
        requestedMergeCandidates = actionEffects.applying(to: requestedMergeCandidates, readRevision: previousRevision)
        fixCandidates = actionEffects.applying(to: fixCandidates, readRevision: previousRevision)
        replyCandidates = actionEffects.applying(to: replyCandidates, readRevision: previousRevision)
        waitingReplyCandidates = actionEffects.applying(to: waitingReplyCandidates, readRevision: previousRevision)
        behindCounts = actionEffects.applying(to: behindCounts, readRevision: previousRevision)
    }

    var readyToMerge: [PullRequest] {
        repositoryFilter.prioritizingFavorites(
            in: filtered(mergeCandidates).excluding(ignoreList.ids).readyToMerge
        )
    }

    var needingCIFix: [PullRequest] {
        repositoryFilter.prioritizingFavorites(
            in: filtered(fixCandidates).excluding(ignoreList.ids).needingCIFix
        )
    }

    var needingRebase: [PullRequest] {
        repositoryFilter.prioritizingFavorites(
            in: filtered(mergeCandidates).excluding(ignoreList.ids).needingRebase
        )
    }

    var needingReply: [PullRequest] {
        repositoryFilter.prioritizingFavorites(
            in: filtered(replyCandidates).excluding(ignoreList.ids)
        )
    }

    var waitingForReply: [PullRequest] {
        repositoryFilter.prioritizingFavorites(
            in: filtered(waitingReplyCandidates).excluding(ignoreList.ids)
        )
    }

    /// Badge count: everything awaiting the user's action. Includes reviews, merges, CI fixes, conflicts, and replies. Deduplicate by ID because an optional failed check can appear in both fix and merge queues.
    var actionableCount: Int {
        Set(awaitingYourReview.map(\.id))
            .union(readyToMerge.map(\.id))
            .union(needingCIFix.map(\.id))
            .union(needingRebase.map(\.id))
            .union(needingReply.map(\.id))
            .count
    }

    /// Tooltip breakdown explaining which categories contribute to the badge count.
    var actionableSummary: String {
        let review = awaitingYourReview.count
        let merge = readyToMerge.count
        let fix = needingCIFix.count
        let rebase = needingRebase.count
        let reply = needingReply.count
        let parts = [
            review > 0 ? L10n.text(.summaryReview, String(review)) : nil,
            merge > 0 ? L10n.text(.summaryMerge, String(merge)) : nil,
            fix > 0 ? L10n.text(.summaryFix, String(fix)) : nil,
            rebase > 0 ? L10n.text(.summaryRebase, String(rebase)) : nil,
            reply > 0 ? L10n.text(.summaryReply, String(reply)) : nil
        ].compactMap(\.self)
        return parts.isEmpty ? L10n.text(.commonNothingPending) : parts.joined(separator: " · ")
    }

    /// Ignored items still open and in the user's queue. Closed items disappear from query results.
    var ignored: [PullRequest] {
        repositoryFilter.prioritizingFavorites(
            in: filtered(allKnown).only(ignoreList.ids)
                .sorted { $0.updatedAt > $1.updatedAt }
        )
    }

    // MARK: - Actions

    func setAutomationFilter(_ filter: AutomationFilter) {
        guard automationFilter != filter else { return }
        autopilot.pauseForScopeChange()
        automationFilter = filter
        automationFilter.persist()
        reconcileBatch()
        onChange?()
    }

    func clearFilters() {
        if automationFilter.isActive { autopilot.pauseForScopeChange() }
        automationFilter = .all
        automationFilter.persist()
        clearRepositoryFilter()
    }

    func toggleRepositoryFavorite(_ repository: String) {
        repositoryFilter.toggleFavorite(repository)
        repositoryFilterDidChange()
    }

    func toggleRepositorySolo(_ repository: String) {
        autopilot.pauseForScopeChange()
        repositoryFilter.toggleSolo(repository)
        repositoryFilterDidChange()
    }

    func toggleRepositoryMute(_ repository: String) {
        autopilot.pauseForScopeChange()
        repositoryFilter.toggleMute(repository)
        repositoryFilterDidChange()
    }

    func clearRepositoryFilter() {
        if repositoryFilter.isActive { autopilot.pauseForScopeChange() }
        repositoryFilter.clearSelection()
        repositoryFilterDidChange()
    }

    private func repositoryFilterDidChange() {
        repositoryFilter.persist()
        reconcileBatch()
        onChange?()
    }

    func perform(_ action: PullRequestAction, onID pullRequestID: PullRequest.ID) {
        // Callbacks and confirmations can outlive a refresh. Resolve by ID to avoid writing with the object captured by the row.
        guard let pullRequest = currentPullRequest(id: pullRequestID) else { return }
        if action.writesToGitHub {
            guard availableWriteActions(for: pullRequest).contains(action) else { return }
        }
        switch action {
        case .open:
            NSWorkspace.shared.open(pullRequest.url)
        case .ignore:
            ignoreList.ignore(pullRequest)
            activity.record(action, on: pullRequest)
        case .restore:
            ignoreList.restore(pullRequest)
            activity.record(action, on: pullRequest)
        case .dependabotRebase:
            guard pullRequest.canRequestDependabotRebase(
                behindBy: behindCount(for: pullRequest)
            ) else {
                activity.record(action, on: pullRequest,
                    status: .failed(LocalizedMessage(L10n.text(.errorDependabotRebase, pullRequest.shortRepository))))
                break
            }
            write(.dependabotRebase(
                repository: pullRequest.repository,
                number: pullRequest.number
            ), on: pullRequest)
        case .approve:
            write(.approve(
                repository: pullRequest.repository,
                number: pullRequest.number
            ), on: pullRequest)
        case .rebase:
            guard pullRequest.canRebase(behindBy: behindCount(for: pullRequest)) else { return }
            write(.rebase(
                repository: pullRequest.repository,
                number: pullRequest.number
            ), on: pullRequest)
        case .merge:
            // The repository defines the method. If unknown, merging is unavailable; reaching this point without a method is a bug.
            guard let method = pullRequest.defaultMergeMethod else {
                activity.record(action, on: pullRequest,
                    status: .failed(LocalizedMessage(L10n.text(.errorMergeMethod, pullRequest.shortRepository))))
                break
            }
            write(.merge(
                repository: pullRequest.repository,
                number: pullRequest.number,
                method: method
            ), on: pullRequest)
        }
        // Ignoring and restoring items change the badge count.
        reconcileBatch()
        onChange?()
        if action == .open {
            refresh(force: true)
        }
    }

    func openProject(_ pr: PullRequest, folder: URL) async {
        guard !projectOpener.isOpening else { return }
        let id = activity.record(title: LocalizedMessage(L10n.text(.editorOpen)),
            target: "\(pr.repository) #\(pr.number)", detail: pr.title, url: pr.url,
            symbol: "chevron.left.forwardslash.chevron.right", status: .running)
        await projectOpener.open(.init(pullRequest: pr, folder: folder)) { try await self.editor.open($0) }
        if let warning = projectOpener.warning {
            activity.update(id, status: .skipped(LocalizedMessage(warning.text)))
        } else if let error = projectOpener.error {
            activity.update(id, status: .failed(LocalizedMessage(error.localizedDescription)))
        } else {
            activity.update(id, status: .succeeded)
        }
    }

    func openProjectWithoutBranch() async {
        guard !projectOpener.isOpening, let warning = projectOpener.warning else { return }
        let request = warning.request
        if warning.target == .agent {
            let title = currentPullRequest(id: request.pullRequestID)?.title
            await projectOpener.openWithoutBranch { await self.launchAgent(request, title: title, folder: $0) }
            return
        }
        await projectOpener.openWithoutBranch { try await self.editor.open($0) }
        if let error = projectOpener.error {
            activity.record(title: LocalizedMessage(L10n.text(.editorOpenProject)),
                target: "\(request.repository) #\(request.url.lastPathComponent)", url: request.url,
                symbol: "chevron.left.forwardslash.chevron.right",
                status: .failed(LocalizedMessage(error.localizedDescription)))
        }
    }

    func openAgent(_ pr: PullRequest, folder: URL) async {
        guard !agentCLI.isOpening, !projectOpener.isOpening else { return }
        let request = LocalBranchCheckout.Request(pullRequest: pr, folder: folder)
        await projectOpener.open(request, target: .agent) {
            await self.launchAgent(request, title: pr.title, folder: $0)
        }
        if let warning = projectOpener.warning {
            activity.record(title: LocalizedMessage(self.agentCLI.openTitle), target: "\(pr.repository) #\(pr.number)",
                detail: pr.title, url: pr.url, symbol: "terminal", status: .skipped(LocalizedMessage(warning.text)))
        } else if let error = projectOpener.error {
            activity.record(title: LocalizedMessage(self.agentCLI.openTitle), target: "\(pr.repository) #\(pr.number)",
                detail: pr.title, url: pr.url, symbol: "terminal", status: .failed(LocalizedMessage(error.localizedDescription)))
        }
    }

    private func launchAgent(_ request: LocalBranchCheckout.Request, title detail: String?, folder: URL) async {
        let title = agentCLI.openTitle
        let id = UUID()
        await agentCLI.open(folder, id: request.pullRequestID) { [activity] result in
            guard case .failure(let error) = result else { return }
            // A custom terminal can fail after launch.
            activity.record(id: id, title: LocalizedMessage(title),
                target: "\(request.repository) #\(request.url.lastPathComponent)",
                detail: detail ?? "", url: request.url, symbol: "terminal",
                status: .failed(LocalizedMessage(error.localizedDescription)))
        }
    }

    func isIgnored(_ pullRequest: PullRequest) -> Bool {
        ignoreList.contains(pullRequest)
    }

    /// `nil` means measurement failed; it does not mean zero.
    func behindCount(for pullRequest: PullRequest) -> Int? {
        behindCounts[pullRequest.id]
    }

    /// All known items, deduplicated: review and merge queues overlap when the user has approved a PR.
    private var allKnown: [PullRequest] {
        // Review is a partial query and must not overwrite merge data, including BLOCKED/UNKNOWN states from the latest refresh.
        (mergeCandidates + reviewQueue + fixCandidates + replyCandidates + waitingReplyCandidates).uniquedByID()
    }

    func currentPullRequest(id: PullRequest.ID) -> PullRequest? {
        allKnown.first { $0.id == id }
    }

    func availableWriteActions(for pr: PullRequest) -> [PullRequestAction] {
        guard !activity.needsVerification(for: pr, viewer: viewerLogin) else { return [] }
        return pr.availableWriteActions(behindBy: behindCount(for: pr))
    }

    func isAvailable(_ pending: PendingPullRequestAction) -> Bool {
        !inFlightActions.contains(pending.pullRequestID)
            && currentPullRequest(id: pending.pullRequestID).map { availableWriteActions(for: $0).contains(pending.action) } == true
            && pending.isAvailable(for: currentPullRequest(id: pending.pullRequestID),
                                   behindBy: behindCounts[pending.pullRequestID])
    }

    func isActing(on pullRequest: PullRequest) -> Bool {
        inFlightActions.contains(pullRequest.id)
    }

    func actionToVerify(for pr: PullRequest) -> ActivityLog.Entry? {
        guard let entry = activity.unconfirmedAction(for: pr, viewer: viewerLogin), canVerify(entry) else { return nil }
        return entry
    }

    private func canVerify(_ entry: ActivityLog.Entry) -> Bool {
        entry.status.needsVerification && entry.action?.batchAction != nil
            && entry.viewer != nil && entry.viewer?.lowercased() == viewerLogin?.lowercased()
            && entry.pullRequest.map { !inFlightActions.contains($0.id) } == true
    }

    /// Only query GitHub. Verification never repeats an uncertain write.
    func verifyAction(_ id: UUID,
                        read: @Sendable (PullRequest, String, PullRequestBatchAction) async throws -> PullRequestActionCheck.Snapshot = {
                            try await PullRequestActionCheck.fetch($0, viewer: $1, action: $2)
                        }) async {
        guard let entry = activity.entries.first(where: { $0.id == id }), canVerify(entry),
              let original = entry.pullRequest, let action = entry.action?.batchAction,
              let viewer = entry.viewer else { return }
        let revision = configurationRevision
        inFlightActions.insert(original.id)
        activity.update(id, status: .checking)
        defer {
            inFlightActions.remove(original.id)
            reconcileBatch()
            onChange?()
        }
        do {
            let snapshot = try await read(original, viewer, action)
            guard revision == configurationRevision else { throw PullRequestActionSkipped(reason: .scopeChanged) }
            guard snapshot.viewer.lowercased() == viewer.lowercased(), viewerLogin?.lowercased() == viewer.lowercased() else {
                throw PullRequestActionSkipped(reason: .accountChanged)
            }
            guard let current = snapshot.pullRequest else {
                activity.update(id, status: .skipped(LocalizedMessage(L10n.text(.batchClosed))))
                return
            }
            guard current.id == original.id, current.repository == original.repository,
                  current.headRefOID == original.headRefOID, current.baseRefName == original.baseRefName else {
                activity.update(id, status: .skipped(LocalizedMessage(L10n.text(.batchChanged))))
                return
            }
            if action == .merge ? snapshot.isMerged : current.approvedByMe {
                applyCompletedAction(action.action, on: original)
                activity.update(id, status: .succeeded)
            } else if !snapshot.isOpen {
                activity.update(id, status: .skipped(LocalizedMessage(L10n.text(.batchClosed))))
            } else {
                // Verification does not authorize another write. Users can retry from the PR menu; Start continues with other items.
                autopilot.stop()
                activity.update(id, status: .failed(LocalizedMessage(L10n.text(.activityNotRecorded))))
            }
        } catch {
            activity.update(id, status: .uncertain(LocalizedMessage(error.localizedDescription)))
        }
    }

    /// Validate, save, and apply the scope without restarting the app.
    func updateConfiguration(organizations: Set<String>, machineAccounts: String,
                             teamDependabotEnabled: Bool? = nil, dependabotTeams: Set<String>? = nil) throws {
        let updated = try AppConfiguration(
            organizations: organizations,
            machineAccountsText: machineAccounts,
            teamDependabotEnabled: teamDependabotEnabled ?? configuration.teamDependabotEnabled,
            dependabotTeams: dependabotTeams ?? configuration.dependabotTeams
        )
        guard updated != configuration else { return }

        autopilot.pauseForScopeChange()
        configuration = updated
        configuration.persist()
        configurationRevision += 1
        actionEffects.reset()
        viewerLogin = nil
        inFlight?.cancel()
        inFlight = nil
        hasPendingRefresh = false

        // Hide data from the previous scope while the new scope loads.
        pullRequests = []
        dependabotPullRequests = []
        requestedMergeCandidates = []
        teamDependabotPullRequests = []
        teamDependabotFailure = nil
        isLoadingTeamDependabot = false
        fixCandidates = []
        replyCandidates = []
        waitingReplyCandidates = []
        behindCounts = [:]
        lastUpdated = nil
        state = .idle
        notificationTracker.resetBaseline()
        reconcileBatch()
        onChange?()
        refresh(force: true)
    }

    private func write(_ operation: GitHubWrite, on pullRequest: PullRequest) {
        // One write per PR at a time: double-clicking must not send two merges.
        guard inFlightActions.insert(pullRequest.id).inserted else { return }
        reconcileBatch()
        onChange?()

        let activityID = activity.record(operation.action, on: pullRequest, status: .pending, viewer: viewerLogin)
        let revision = configurationRevision
        let viewer = viewerLogin
        Task {
            var submitted = false
            do {
                if let action = operation.action.batchAction {
                    guard let viewer else { throw GH.Failure.badJSON("Missing viewer") }
                    let result = try await GitHubActionRunner.shared.perform(
                        pullRequest, viewer: viewer, action: action, batch: false,
                        read: { try await PullRequestActionCheck.fetch($0, viewer: $1, action: action) },
                        write: { try await GitHubActionRunner.submit($0, action: action) },
                        isAllowed: { [self] _ in revision == configurationRevision },
                        progress: { [activity] progress in
                            if case .executing = progress { submitted = true } else { submitted = false }
                            switch progress {
                            case .checking: activity.update(activityID, status: .checking)
                            case .executing: activity.update(activityID, status: .running)
                            case .waiting(let seconds, let attempt):
                                activity.update(activityID, status: .waiting(seconds: seconds, attempt: attempt))
                            }
                        }
                    )
                    if case .skipped(let reason) = result, reason != .alreadyApproved && reason != .alreadyMerged {
                        throw PullRequestActionSkipped(reason: reason)
                    }
                } else {
                    // Other writes retain a single attempt: transport errors can arrive after the action was applied.
                    submitted = true
                    activity.update(activityID, status: .running)
                    _ = try await GH.run(operation.arguments)
                }

                if revision == configurationRevision, viewer?.lowercased() == viewerLogin?.lowercased() {
                    applyCompletedAction(operation.action, on: pullRequest)
                }

                activity.update(activityID, status: .succeeded)
            } catch let error as PullRequestActionSkipped {
                activity.update(activityID, status: .skipped(LocalizedMessage(error.reason.text)))
            } catch {
                let message = LocalizedMessage(error.localizedDescription)
                activity.update(activityID, status: operation.action.batchAction != nil && GitHubActionRunner.needsVerification(error, submitted: submitted)
                                ? .uncertain(message) : .failed(message))
            }
            inFlightActions.remove(pullRequest.id)
            reconcileBatch()
            onChange?()
            // Refresh all queues afterward, even when GitHub returned an error and the write outcome is unknown.
            refresh(force: true)
        }
    }

    // MARK: - Loading

    func refresh(force: Bool = false) {
        if !force, let lastUpdated, Date().timeIntervalSince(lastUpdated) < Self.staleAfter {
            return
        }
        guard inFlight == nil else {
            if force { hasPendingRefresh = true }
            return
        }

        state = .loading
        onChange?()

        let requestedConfiguration = configuration
        let requestedRevision = configurationRevision
        let readRevision = actionEffects.revision
        let requestedTeamDiscovery = forceTeamDiscovery
        forceTeamDiscovery = false
        isLoadingTeamDependabot = !requestedConfiguration.effectiveDependabotTeams.isEmpty

        // No `weak self`: the store lives as long as the app.
        inFlight = Task {
            await Diagnostics.refresh(.github, forced: force) {
                var firstContent = false
                do {
                    try await Diagnostics.measure(.preflight) { try await GH.preflight() }
                    // One identity per refresh, with no cache across accounts or cycles.
                    let viewer = try await Viewer.fetch()
                    guard requestedRevision == configurationRevision, !Task.isCancelled else { return }
                    if let previous = viewerLogin, previous.lowercased() != viewer.login.lowercased() {
                        actionEffects.reset()
                    }
                    viewerLogin = viewer.login
                    // Stop immediately if the account changes, even if a query fails.
                    autopilot.reconcile(batchCandidates, viewer: viewer.login)

                    let completed = try await GitHubQueueRefresh.load(queries: .live(
                        configuration: requestedConfiguration, viewer: viewer,
                        forceTeamDiscovery: requestedTeamDiscovery
                    )) { update in
                        guard requestedRevision == self.configurationRevision, !Task.isCancelled else { return }
                        self.publish(update, readRevision: readRevision, firstContent: &firstContent)
                    }
                    guard requestedRevision == configurationRevision, !Task.isCancelled else { return }
                    // Publish independently; notifications wait for complete sources to avoid treating a backlog as new activity.
                    if completed.canNotifyMerge {
                        await Diagnostics.measure(.notifications) {
                            await notifier.send(notificationTracker.process(readyToMerge, in: .merge))
                        }
                        guard requestedRevision == configurationRevision, !Task.isCancelled else { return }
                    }
                    if completed.canNotifyReview {
                        await Diagnostics.measure(.notifications) {
                            await notifier.send(notificationTracker.process(awaitingYourReview, in: .review))
                        }
                        guard requestedRevision == configurationRevision, !Task.isCancelled else { return }
                    }
                    // An empty state is valid only after querying all queues. Subsequent branch measurements neither add nor remove PRs.
                    lastUpdated = .now
                    state = .loaded
                    Diagnostics.record(.queuesLoaded)
                    onChange?()
                    let counts = await Diagnostics.measure(.behind) { await BehindCount.fetch(for: allKnown) }
                    guard requestedRevision == configurationRevision, !Task.isCancelled else { return }
                    behindCounts = actionEffects.applying(to: counts, readRevision: readRevision)
                    actionEffects.finishRefresh(startedAt: readRevision)
                } catch {
                    guard requestedRevision == configurationRevision else { return }
                    Diagnostics.record(.failed, error: error)
                    state = .failed(LocalizedMessage(error.localizedDescription))
                }
                guard requestedRevision == configurationRevision else { return }
                inFlight = nil
                isLoadingTeamDependabot = false
                onChange?()
                if hasPendingRefresh {
                    hasPendingRefresh = false
                    refresh(force: true)
                }
            }
        }
    }

    private func publish(_ update: GitHubQueueRefresh.Update, readRevision: Int, firstContent: inout Bool) {
        let phase: Diagnostics.Phase
        let count: Int
        switch update {
        case .review(let prs):
            pullRequests = actionEffects.applying(to: prs, readRevision: readRevision)
            phase = .review
            count = prs.count
        case .merge(let prs):
            requestedMergeCandidates = actionEffects.applying(to: prs, readRevision: readRevision)
            phase = .merge
            count = prs.count
        case .own(let prs):
            fixCandidates = actionEffects.applying(to: prs, readRevision: readRevision)
            phase = .own
            count = prs.count
        case .dependabot(let prs):
            dependabotPullRequests = actionEffects.applying(to: prs, readRevision: readRevision)
            phase = .dependabot
            count = prs.count
        case .team(let result):
            isLoadingTeamDependabot = false
            teamDependabotFailure = result.error.map { LocalizedMessage(L10n.text(.errorTeamDiscovery, $0)) }
            guard let prs = result.pullRequests else { onChange?(); return }
            teamDependabotPullRequests = actionEffects.applying(to: prs, readRevision: readRevision)
            phase = .teamDependabot
            count = prs.count
        case .replies(let replies):
            replyCandidates = actionEffects.applying(to: replies.needingReply, readRevision: readRevision)
            waitingReplyCandidates = actionEffects.applying(to: replies.waitingForReply, readRevision: readRevision)
            phase = .replies
            count = replies.needingReply.count + replies.waitingForReply.count
        }
        recordPublication(phase, count: count, firstContent: &firstContent)
        reconcileBatch()
        onChange?()
    }

    private func recordPublication(_ phase: Diagnostics.Phase, count: Int, firstContent: inout Bool) {
        Diagnostics.record(.published, phase: phase, metrics: [.items: count])
        if !firstContent,
           !reviewSections.isEmpty || !readyToMerge.isEmpty || !needingCIFix.isEmpty
            || !needingRebase.isEmpty || !needingReply.isEmpty || !waitingForReply.isEmpty || !automation.isEmpty || !ignored.isEmpty {
            firstContent = true
            Diagnostics.record(.firstContent)
        }
    }

}

#if DEBUG
extension ReviewQueueStore {
    /// In-memory panel preview data, without remote reads or writes.
    static func preview(reviews: [PullRequest], merges: [PullRequest],
                        batch: PullRequestBatch = PullRequestBatch(), viewer: String = "me",
                        activity: ActivityLog = ActivityLog()) -> ReviewQueueStore {
        let store = ReviewQueueStore(batch: batch, activity: activity)
        store.viewerLogin = viewer
        store.repositoryFilter = RepositoryFilter()
        store.automationFilter = .all
        store.configuration = .empty
        store.pullRequests = reviews
        store.requestedMergeCandidates = merges
        store.state = .loaded
        return store
    }
}
#endif
