import Foundation

/// Dependencias entre consultas de una carga. Publicar no espera a otras colas;
/// la finalización sí espera todas las fuentes necesarias para notificar.
@MainActor
enum GitHubQueueRefresh {
    enum Update: Sendable {
        case review([PullRequest]), merge([PullRequest]), own([PullRequest]), dependabot([PullRequest])
        case team(TeamDependabot.QueueResult)
        case replies(ReplyQueue.Result)
    }

    struct Completion: Sendable {
        let canNotifyMerge: Bool
        let canNotifyReview: Bool
    }

    struct Queries: Sendable {
        typealias PRs = @Sendable () async throws -> [PullRequest]
        var review: PRs
        var merge: PRs
        var own: PRs
        var conversations: PRs
        var dependabot: PRs
        var team: @Sendable () async -> TeamDependabot.QueueResult
        var replies: @Sendable ([PullRequest]) async throws -> ReplyQueue.Result

        static func live(configuration: AppConfiguration, viewer: Viewer, forceTeamDiscovery: Bool) -> Self {
            Self(
                review: { try await ReviewQueue.fetch(configuration: configuration, viewer: viewer) },
                merge: { try await MergeQueue.fetch(configuration: configuration, viewer: viewer) },
                own: { try await FixQueue.fetch(configuration: configuration, viewer: viewer) },
                conversations: { try await ConversationCandidates.fetch(configuration: configuration, viewer: viewer) },
                dependabot: { try await DependabotQueue.fetch(configuration: configuration, viewer: viewer) },
                team: { await TeamDependabot.load(configuration: configuration, viewer: viewer, force: forceTeamDiscovery) },
                replies: { try await ReplyQueue.fetch(for: $0, me: viewer.login) }
            )
        }
    }

    static func load(
        queries: Queries,
        publish: @escaping @MainActor (Update) -> Void
    ) async throws -> Completion {
        @MainActor func fetch(
            _ phase: Diagnostics.Phase, _ query: Queries.PRs,
            update: ([PullRequest]) -> Update
        ) async throws -> [PullRequest] {
            let prs = try await Diagnostics.measure(phase) { try await query() }
            try Task.checkCancellation()
            publish(update(prs))
            return prs
        }

        @MainActor func loadTeam() async throws -> TeamDependabot.QueueResult {
            let result = await Diagnostics.measure(.teamDependabot) { await queries.team() }
            try Task.checkCancellation()
            publish(.team(result))
            return result
        }

        @MainActor func loadOwnAndReplies() async throws {
            async let own = try? fetch(.own, queries.own, update: Update.own)
            async let conversations = Diagnostics.measure(.conversationCandidates) {
                try await queries.conversations()
            }
            // Una falla conserva la última clasificación. Los hilos sólo dependen
            // de estas dos listas, nunca de merge ni de review.
            if let own = await own {
                do {
                    let others = try await conversations
                    try Task.checkCancellation()
                    let replies = try await Diagnostics.measure(.replies) {
                        try await queries.replies(own + others)
                    }
                    try Task.checkCancellation()
                    publish(.replies(replies))
                } catch is CancellationError {
                    throw CancellationError()
                } catch { }
            }
        }

        async let team = loadTeam()
        async let review = fetch(.review, queries.review, update: Update.review)
        async let merge = try? fetch(.merge, queries.merge, update: Update.merge)
        async let ownAndReplies: Void = loadOwnAndReplies()

        _ = try await review // Conserva la prioridad de review al iniciar Dependabot.
        try Task.checkCancellation()
        async let dependabot = try? fetch(.dependabot, queries.dependabot, update: Update.dependabot)

        let (merged, bots, teams, _) = try await (merge, dependabot, team, ownAndReplies)
        try Task.checkCancellation()
        return Completion(
            canNotifyMerge: merged != nil && teams.pullRequests != nil,
            canNotifyReview: bots != nil && teams.pullRequests != nil
        )
    }
}
