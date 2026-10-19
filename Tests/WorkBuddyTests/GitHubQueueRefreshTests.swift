import Foundation
import Testing
@testable import WorkBuddy

@Suite("Independent queue publication")
@MainActor
struct GitHubQueueRefreshTests {
    @Test("Publish own PRs, teams, and replies while review and merge remain pending")
    func independentPublication() async throws {
        let fixture = QueueRefreshFixture()
        var publications: [Diagnostics.Phase] = []
        var completed = false
        let task = Task {
            let result = try await GitHubQueueRefresh.load(queries: queries(fixture)) {
                if let phase = publicationPhase($0) { publications.append(phase) }
            }
            completed = true
            return result
        }
        defer { task.cancel(); Task { await fixture.releaseAll() } }
        try await fixture.waitFor([.review, .merge, .own, .conversationCandidates, .teamDependabot])
        await fixture.release([.own, .teamDependabot])
        try await waitUntil { Set(publications) == [.own, .teamDependabot] }

        await fixture.release([.conversationCandidates])
        try await fixture.waitFor([.replies])
        await fixture.release([.replies])
        try await waitUntil { publications.contains(.replies) }
        #expect(!completed)
        #expect(!(await fixture.started).contains(.dependabot))

        await fixture.release([.review])
        try await fixture.waitFor([.dependabot])
        await fixture.release([.dependabot])
        try await waitUntil { publications.contains(.dependabot) }
        #expect(!completed) // The cycle cannot finish or notify merges yet.
        #expect(!publications.contains(.merge))

        await fixture.release([.merge])
        let result = try await task.value
        #expect(result.canNotifyMerge && result.canNotifyReview)
        #expect(Set(publications) == [.own, .teamDependabot, .replies, .review, .dependabot, .merge])
        #expect(publications.count == 6)
    }

    @Test("Failed secondary sources retain their section and limit notifications",
          arguments: [Diagnostics.Phase.merge, .dependabot, .teamDependabot, .own, .conversationCandidates, .replies])
    func partialFailures(failing: Diagnostics.Phase) async throws {
        let fixture = QueueRefreshFixture(failing: failing)
        await fixture.releaseAll()
        var publications: [Diagnostics.Phase] = []
        let result = try await GitHubQueueRefresh.load(queries: queries(fixture)) {
            if let phase = publicationPhase($0) { publications.append(phase) }
        }
        #expect(!publications.contains(failing))
        #expect(publications.contains(.review))
        #expect(result.canNotifyMerge == (failing != .merge && failing != .teamDependabot))
        #expect(result.canNotifyReview == (failing != .dependabot && failing != .teamDependabot))
        if failing == .own || failing == .conversationCandidates {
            #expect(!(await fixture.started).contains(.replies))
            #expect(!publications.contains(.replies))
        }
    }

    @Test("Cancellation prevents publishing late responses")
    func cancellation() async throws {
        let fixture = QueueRefreshFixture()
        var publications: [Diagnostics.Phase] = []
        let task = Task {
            try await GitHubQueueRefresh.load(queries: queries(fixture)) {
                if let phase = publicationPhase($0) { publications.append(phase) }
            }
        }
        defer { task.cancel(); Task { await fixture.releaseAll() } }
        try await fixture.waitFor([.review, .merge, .own, .conversationCandidates, .teamDependabot])
        task.cancel()
        await fixture.releaseAll()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(publications.isEmpty)
    }

    @Test("Review failures remain fatal and do not start Dependabot")
    func reviewFailure() async throws {
        let fixture = QueueRefreshFixture(failing: .review)
        await fixture.releaseAll()
        await #expect(throws: GH.Failure.self) {
            try await GitHubQueueRefresh.load(queries: queries(fixture)) { _ in }
        }
        #expect(!(await fixture.started).contains(.dependabot))
    }

    private func queries(_ fixture: QueueRefreshFixture) -> GitHubQueueRefresh.Queries {
        .init(
            review: { try await fixture.run(.review); return [] },
            merge: { try await fixture.run(.merge); return [] },
            own: { try await fixture.run(.own); return [] },
            conversations: { try await fixture.run(.conversationCandidates); return [] },
            dependabot: { try await fixture.run(.dependabot); return [] },
            team: {
                do {
                    try await fixture.run(.teamDependabot)
                    return .init(pullRequests: [], error: nil)
                } catch { return .init(pullRequests: nil, error: "fixture") }
            },
            replies: { _ in
                try await fixture.run(.replies)
                return .init(needingReply: [], waitingForReply: [])
            }
        )
    }

    private func publicationPhase(_ update: GitHubQueueRefresh.Update) -> Diagnostics.Phase? {
        switch update {
        case .review: .review
        case .merge: .merge
        case .own: .own
        case .dependabot: .dependabot
        case .replies: .replies
        case .team(let result): result.pullRequests == nil ? nil : .teamDependabot
        }
    }

    private func waitUntil(_ predicate: () -> Bool) async throws {
        for _ in 0..<200 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw GH.Failure.noAttempts
    }
}

private actor QueueRefreshFixture {
    private let failing: Diagnostics.Phase?
    private var pending: [Diagnostics.Phase: CheckedContinuation<Void, Never>] = [:]
    private var automatic = false
    private(set) var started: Set<Diagnostics.Phase> = []

    init(failing: Diagnostics.Phase? = nil) { self.failing = failing }

    func run(_ phase: Diagnostics.Phase) async throws {
        #expect(started.insert(phase).inserted)
        if !automatic { await withCheckedContinuation { pending[phase] = $0 } }
        // Simulate a gh process that can respond after loading is canceled.
        if phase == failing { throw GH.Failure.noAttempts }
    }

    func release(_ phases: Set<Diagnostics.Phase>) {
        for phase in phases { pending.removeValue(forKey: phase)?.resume() }
    }

    func releaseAll() {
        automatic = true
        let continuations = Array(pending.values)
        pending.removeAll()
        for continuation in continuations { continuation.resume() }
    }

    func waitFor(_ phases: Set<Diagnostics.Phase>) async throws {
        for _ in 0..<200 {
            if phases.isSubset(of: started) { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw GH.Failure.noAttempts
    }
}
