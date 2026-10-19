import Foundation

/// Development-only review queue dump to stdout.
/// Checks data loading and classification without the GUI.
enum DumpQueue {
    @MainActor
    static func run() async {
        do {
            try await GH.preflight()
            let start = Date()
            let configuration = AppConfiguration.load()
            let viewer = try await Viewer.fetch()

            // Queue requests are independent. The app publishes early results to show
            // the panel sooner; this dump runs requests concurrently because only the final result matters.
            async let reviewQueue = ReviewQueue.fetch(configuration: configuration, viewer: viewer)
            async let dependabotQueue = DependabotQueue.fetch(configuration: configuration, viewer: viewer)
            async let teamQueue = TeamDependabot.load(configuration: configuration, viewer: viewer)
            async let mergeQueue = MergeQueue.fetch(configuration: configuration, viewer: viewer)
            async let conversationCandidates = ConversationCandidates.fetch(configuration: configuration, viewer: viewer)
            async let fixQueue = FixQueue.fetch(configuration: configuration, viewer: viewer)

            let humans = try await reviewQueue
            let dependabot = try await dependabotQueue
            let teamResult = await teamQueue
            if let error = teamResult.error {
                FileHandle.standardError.write(Data("Team Dependabot: \(error)\n".utf8))
            }
            let teamPRs = teamResult.pullRequests ?? []
            let mergeCandidates = (try await mergeQueue + teamPRs).uniquedByID()
            let fixCandidates = try await fixQueue
            let others = try await conversationCandidates
            let replies = try await ReplyQueue.fetch(for: fixCandidates + others, me: viewer.login)
            let pullRequests = (humans + dependabot + teamPRs).uniquedByID()
            let elapsed = Date().timeIntervalSince(start)

            // Apply the same ignored-item list as the panel so the dump reflects the UI.
            let ignoredIDs = IgnoreList().ids
            let visible = pullRequests.excluding(ignoredIDs)
                .excludingMergeableAutomation(in: mergeCandidates)
            let readyToMerge = mergeCandidates.excluding(ignoredIDs).readyToMerge
            let needingCIFix = fixCandidates.excluding(ignoredIDs).needingCIFix
            let needingRebase = mergeCandidates.excluding(ignoredIDs).needingRebase
            let needingReply = replies.needingReply.excluding(ignoredIDs)
            let waitingForReply = replies.waitingForReply.excluding(ignoredIDs)

            var seen: Set<String> = []
            let allKnown = (pullRequests + mergeCandidates + fixCandidates + replies.needingReply + replies.waitingForReply)
                .filter { seen.insert($0.id).inserted }
            let ignored = allKnown.only(ignoredIDs)
            let behind = await BehindCount.fetch(for: allKnown)

            let reviews = visible.reviewSections.flatMap(\.items)
            let bots = visible.automation

            // Match the badge calculation across action sources, deduplicated by ID.
            let awaiting = visible.awaitingYourReview
            let badge = Set(awaiting.map(\.id)).union(readyToMerge.map(\.id))
                .union(needingCIFix.map(\.id)).union(needingRebase.map(\.id))
                .union(needingReply.map(\.id)).count

            print("\(pullRequests.count) PRs in queue — \(format(elapsed))")
            print("  people: \(humans.count)  |  dependabot: \(dependabot.count)  |  team Dependabot: \(teamPRs.count)")
            print("visible → reviews: \(reviews.count)"
                + "  |  automation: \(bots.count)"
                + "  |  ignored: \(ignored.count)")
            print("BADGE: \(badge)  (\(awaiting.count) to review + "
                + "\(readyToMerge.count) to merge + \(needingCIFix.count) to fix + "
                + "\(needingRebase.count) to rebase + \(needingReply.count) to reply)\n")

            print("── READY TO MERGE (\(readyToMerge.count)) ──")
            for pullRequest in readyToMerge {
                print("  \(describe(pullRequest, behind: behind))  "
                    + "[\(pullRequest.mergeStateStatus?.rawValue ?? "?")]")
            }
            print("")

            print("── NEEDS FIXES (\(needingCIFix.count)) ──")
            for pullRequest in needingCIFix {
                print("  \(describe(pullRequest, behind: behind))")
            }
            print("")

            print("── NEEDS REBASE (\(needingRebase.count)) ──")
            for pullRequest in needingRebase {
                print("  \(describe(pullRequest, behind: behind))")
            }
            print("")

            print("── NEEDS REPLY (\(needingReply.count)) ──")
            for pullRequest in needingReply {
                print("  \(describe(pullRequest, behind: behind))")
            }
            print("")

            print("── AWAITING REPLY (\(waitingForReply.count)) ──")
            for pullRequest in waitingForReply {
                print("  \(describe(pullRequest, behind: behind))")
            }
            print("")

            print("── REVIEWS ──")
            printBuckets(reviews, behind: behind, listing: true)

            // List automation like human PRs: its distance behind the base helps users
            // decide whether a rebase is appropriate and must remain visible in the dump.
            print("── AUTOMATION · NOT READY ──")
            for pullRequest in bots {
                print("  \(describe(pullRequest, behind: behind))")
            }
            print("")

            if !ignored.isEmpty {
                print("── IGNORED ──")
                printBuckets(ignored, behind: behind, listing: true)
            }
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            FileHandle.standardError.write(Data("Error: \(message)\n".utf8))
            exit(1)
        }
    }

    private static func printBuckets(
        _ pullRequests: [PullRequest],
        behind: [String: Int],
        listing: Bool
    ) {
        let grouped = Dictionary(grouping: pullRequests) { $0.bucket() }
        for bucket in ReviewBucket.allCases {
            let items = grouped[bucket] ?? []
            guard !items.isEmpty else { continue }
            print("\(bucket.title) (\(items.count))")
            guard listing else { continue }
            for pullRequest in items.sorted(by: { $0.updatedAt > $1.updatedAt }) {
                print("  \(describe(pullRequest, behind: behind))")
            }
        }
        // These remain relevant to automation, merge, and ignored sections
        // even when they no longer belong to a panel review category.
        let outsideReview = pullRequests.filter { $0.bucket() == nil }
        if !outsideReview.isEmpty {
            print("Outside the review queue (\(outsideReview.count))")
            if listing {
                for pullRequest in outsideReview.sorted(by: { $0.updatedAt > $1.updatedAt }) {
                    print("  \(describe(pullRequest, behind: behind))")
                }
            }
        }
        print("")
    }

    private static func describe(_ pullRequest: PullRequest, behind: [String: Int]) -> String {
        // Unknown (?) and up to date (empty) are distinct states.
        let lag: String? = switch behind[pullRequest.id] {
        case .some(let commits) where commits > 0: "↓\(commits)"
        case .none: "↓?"
        default: nil
        }
        let flags = [
            pullRequest.checks.isRed ? "CI✗" : nil,
            pullRequest.isDraft ? "draft" : nil,
            pullRequest.approvals > 0 ? "\(pullRequest.approvals)✓" : nil,
            lag
        ].compactMap(\.self).joined(separator: " ")
        return "\(pullRequest.shortRepository)#\(pullRequest.number) "
            + "@\(pullRequest.author.login) — \(pullRequest.title.prefix(46)) \(flags)"
    }

    private static func format(_ seconds: TimeInterval) -> String {
        String(format: "%.1fs", seconds)
    }
}
