import Foundation
import Testing

@testable import WorkBuddy

@Suite("Filtro de repositorios")
struct RepositoryFilterTests {
    @Test("Solo es exclusivo, ignora mayúsculas y conserva los muteos")
    func soloAndMute() {
        var filter = RepositoryFilter()
        filter.toggleMute("Org/API")
        #expect(!filter.includes("org/api"))
        #expect(filter.includes("org/web"))

        filter.toggleSolo("ORG/API")
        #expect(filter.includes("org/api"))
        #expect(!filter.includes("org/web"))
        filter.toggleSolo("org/web")
        #expect(!filter.includes("org/api"))
        #expect(filter.includes("org/web"))
        filter.toggleSolo("ORG/WEB")
        #expect(filter.solo == nil)
        #expect(!filter.includes("org/api"))
        #expect(filter.includes("org/new-repo"))
        filter.toggleMute("org/api")
        #expect(!filter.isActive)
    }

    @Test("Mutear el repo en solo sale de solo y lo oculta")
    func muteSolo() {
        var filter = RepositoryFilter()
        filter.toggleMute("org/other")
        filter.toggleSolo("org/api")
        filter.toggleMute("org/api")
        #expect(filter.solo == nil)
        #expect(!filter.includes("org/api"))
        #expect(!filter.includes("org/other"))
        #expect(filter.includes("org/web"))
    }

    @Test("Restaura Solo y Mute desde preferencias y permite limpiar ambos")
    func persistence() throws {
        let suiteName = "repository-filter-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        #expect(!RepositoryFilter.load(defaults: defaults).isActive)
        var filter = RepositoryFilter()
        filter.toggleMute("org/api")
        filter.toggleSolo("org/web")
        filter.persist(defaults: defaults)
        let reopenedDefaults = try #require(UserDefaults(suiteName: suiteName))
        let restored = RepositoryFilter.load(defaults: reopenedDefaults)
        #expect(restored == filter)
        #expect(!restored.includes("org/api"))
        #expect(restored.includes("org/web"))
        RepositoryFilter().persist(defaults: defaults)
        #expect(!RepositoryFilter.load(defaults: reopenedDefaults).isActive)
    }

    @Test("Distinct usa todos los resultados y conserva preferencias sin resultados")
    func distinctRepositories() {
        var filter = RepositoryFilter()
        filter.toggleMute("org/api")
        filter.toggleMute("org/gone")
        filter.toggleSolo("org/empty")
        let review = pullRequest("review", repository: "Org/API")
        let merge = pullRequest("merge", repository: "org/web")
        let repositories = filter.repositories(in: [review, review, merge])
        #expect(repositories.map(\.id) == ["org/api", "org/empty", "org/gone", "org/web"])
        #expect(repositories.map(\.pullRequestCount) == [1, 0, 0, 1])
        #expect(filter.repositories(in: []).map(\.id) == ["org/api", "org/empty", "org/gone"])
    }

    @Test("El filtro compone con reviews, automatización, merge e ignorados")
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
        #expect(solo.automation.map(\.id) == ["bot"])
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
            reviewedByMe: false, approvals: 0
        )
    }
}
