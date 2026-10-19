import Foundation
import Testing

@testable import WorkBuddy

@Suite("Repository filter")
struct RepositoryFilterTests {
    @Test("Solo supports multiple repositories, ignores case, and clears mutes")
    func soloAndMute() {
        var filter = RepositoryFilter()
        filter.toggleMute("Org/API")
        #expect(!filter.includes("org/api"))
        #expect(filter.includes("org/web"))

        filter.toggleSolo("ORG/API")
        #expect(filter.muted.isEmpty)
        #expect(filter.includes("org/api"))
        #expect(!filter.includes("org/web"))
        filter.toggleSolo("org/web")
        #expect(filter.includes("org/api"))
        #expect(filter.includes("org/web"))
        #expect(!filter.includes("org/new-repo"))
        filter.toggleSolo("ORG/WEB")
        #expect(filter.solo == ["org/api"])
        #expect(!filter.includes("org/web"))
        filter.toggleSolo("org/api")
        #expect(filter.solo.isEmpty)
        #expect(filter.includes("org/new-repo"))
        #expect(!filter.isActive)
    }

    @Test("Muting any repository clears solo selections and supports multiple mutes")
    func muteSolo() {
        var filter = RepositoryFilter()
        filter.toggleSolo("org/api")
        filter.toggleSolo("org/web")
        filter.toggleMute("org/other")
        #expect(filter.solo.isEmpty)
        #expect(filter.includes("org/api"))
        #expect(!filter.includes("org/other"))
        #expect(filter.includes("org/web"))
        filter.toggleMute("org/api")
        #expect(!filter.includes("org/api"))
        #expect(!filter.includes("org/other"))
        filter.toggleMute("org/other")
        #expect(filter.muted == ["org/api"])
        filter.toggleMute("org/api")
        #expect(!filter.isActive)
    }

    @Test("Persist each mode with multiple repositories and allow clearing the filter")
    func persistence() throws {
        let suiteName = "repository-filter-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        #expect(!RepositoryFilter.load(defaults: defaults).isActive)
        var filter = RepositoryFilter()
        filter.toggleMute("org/api")
        filter.toggleMute("org/other")
        filter.persist(defaults: defaults)
        #expect(RepositoryFilter.load(defaults: defaults) == filter)
        filter.toggleSolo("org/web")
        filter.toggleSolo("org/docs")
        filter.persist(defaults: defaults)
        let reopenedDefaults = try #require(UserDefaults(suiteName: suiteName))
        let restored = RepositoryFilter.load(defaults: reopenedDefaults)
        #expect(restored == filter)
        #expect(!restored.includes("org/api"))
        #expect(restored.includes("org/web"))
        #expect(restored.includes("org/docs"))
        #expect(restored.muted.isEmpty)
        RepositoryFilter().persist(defaults: defaults)
        #expect(!RepositoryFilter.load(defaults: reopenedDefaults).isActive)
    }

    @Test("Migrate legacy solo selection without retaining simultaneous modes")
    func migration() throws {
        let previous = Data(#"{"solo":"Org/API","muted":["org/web"]}"#.utf8)
        let filter = try JSONDecoder().decode(RepositoryFilter.self, from: previous)
        #expect(filter.solo == ["org/api"])
        #expect(filter.muted.isEmpty)
        let muteOnly = Data(#"{"muted":["Org/Web","org/api"]}"#.utf8)
        let migratedMute = try JSONDecoder().decode(RepositoryFilter.self, from: muteOnly)
        #expect(migratedMute.solo.isEmpty)
        #expect(migratedMute.muted == ["org/web", "org/api"])
        let mixed = Data(#"{"solo":["org/api","org/web"],"muted":["org/docs"]}"#.utf8)
        let repaired = try JSONDecoder().decode(RepositoryFilter.self, from: mixed)
        #expect(repaired.solo == ["org/api", "org/web"])
        #expect(repaired.muted.isEmpty)
    }

    @Test("Distinct uses all results and retains preferences without results")
    func distinctRepositories() {
        var filter = RepositoryFilter()
        filter.toggleSolo("org/api")
        filter.toggleSolo("org/gone")
        filter.toggleSolo("org/empty")
        let review = pullRequest("review", repository: "Org/API")
        let merge = pullRequest("merge", repository: "org/web")
        let repositories = filter.repositories(in: [review, review, merge])
        #expect(repositories.map(\.id) == ["org/api", "org/empty", "org/gone", "org/web"])
        #expect(repositories.map(\.pullRequestCount) == [1, 0, 0, 1])
        #expect(filter.repositories(in: []).map(\.id) == ["org/api", "org/empty", "org/gone"])
    }

    @Test("The filter composes with reviews, automation, merge, and ignored items")
    func allQueues() {
        let queue = [
            pullRequest("review", repository: "org/api"),
            pullRequest("bot", repository: "org/api", bot: true),
            pullRequest("merge", repository: "org/api", mine: true),
            pullRequest("ignored", repository: "org/api"),
            pullRequest("other", repository: "org/web")
        ]
        var filter = RepositoryFilter()
        filter.toggleMute("org/api")
        let visible = filter.apply(to: queue)
        #expect(visible.awaitingYourReview.map(\.id) == ["other"])
        #expect(visible.automation.isEmpty)
        #expect(visible.readyToMerge.isEmpty)
        #expect(visible.only(["ignored"]).isEmpty)
        filter.toggleSolo("org/api")
        let solo = filter.apply(to: queue).excluding(["ignored"])
        #expect(solo.count == 3)
        #expect(solo.automation.isEmpty)
        #expect(solo.awaitingYourReview.map(\.id) == ["review", "bot", "merge"])
        #expect(solo.readyToMerge.map(\.id) == ["merge"])
    }

    private func pullRequest(
        _ id: String, repository: String, bot: Bool = false, mine: Bool = false
    ) -> PullRequest {
        PullRequest(
            id: id, number: 1, title: "Cambio", url: URL(string: "https://github.com/\(repository)/pull/1")!,
            repository: repository, baseRefName: "main", headRefName: "change",
            author: Author(login: bot ? "bot" : "person", typename: bot ? "Bot" : "User"),
            updatedAt: .now, isDraft: false, checks: .success, reviewDecision: .reviewRequired,
            mergeable: mine ? .mergeable : nil, mergeStateStatus: mine ? .clean : nil,
            defaultMergeMethod: .squash, authoredByMe: mine, requestedFromMe: true,
            reviewedByMe: false, approvals: 0, approvedByMe: false
        )
    }
}
