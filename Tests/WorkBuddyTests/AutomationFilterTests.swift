import Foundation
import Testing

@testable import WorkBuddy

@Suite("Filtro de automatización")
struct AutomationFilterTests {
    @Test("Incluye Dependabot, otros bots y cuentas de máquina sin adivinar por el login")
    func authorClassification() {
        let prs = [
            pr("dependabot", author: Author(login: "dependabot", typename: "Bot")),
            pr("renovate", author: Author(login: "renovate[bot]", typename: "Bot")),
            pr("machine", author: Author(login: "Release-User", typename: "User", machineAccounts: ["release-user"])),
            pr("person", author: Author(login: "alice", typename: "User")),
            pr("bot-name", author: Author(login: "looks-like-a-bot", typename: "User"))
        ]
        #expect(AutomationFilter.all.apply(to: prs).map(\.id) == prs.map(\.id))
        #expect(AutomationFilter.onlyAutomation.apply(to: prs).map(\.id) == ["dependabot", "renovate", "machine"])
        #expect(AutomationFilter.excludingAutomation.apply(to: prs).map(\.id) == ["person", "bot-name"])
    }

    @Test("Compone con repositorios, favoritos, ignorados y clasificación de colas")
    func queues() {
        let bot = Author(login: "dependabot", typename: "Bot")
        let person = Author(login: "alice", typename: "User")
        let prs = [
            pr("review", author: bot),
            pr("ci", author: bot, checks: .failure),
            pr("merge", author: bot, merge: true),
            pr("ignored", author: bot),
            pr("human", author: person),
            pr("other-repo", author: bot, repository: "org/web")
        ]
        var repositories = RepositoryFilter()
        repositories.toggleSolo("org/api")
        repositories.toggleFavorite("org/web")
        let selected = repositories.apply(to: prs)
        let automated = AutomationFilter.onlyAutomation.apply(to: selected)
        let visible = automated.excluding(["ignored"])
        let reviews = visible.excludingMergeableAutomation(in: visible)
        #expect(reviews.awaitingYourReview.map(\.id) == ["review"])
        #expect(reviews.automation.map(\.id) == ["ci"])
        #expect(visible.readyToMerge.map(\.id) == ["merge"])
        #expect(automated.only(["ignored"]).map(\.id) == ["ignored"])
        #expect(Set(reviews.awaitingYourReview.map(\.id)).union(visible.readyToMerge.map(\.id)).count == 2)
        let humans = AutomationFilter.excludingAutomation.apply(to: selected)
        #expect(humans.map(\.id) == ["human"])
        #expect(humans.automation.isEmpty)
        #expect(humans.readyToMerge.isEmpty)
        #expect(repositories.prioritizingFavorites(in: automated).map(\.id) == automated.map(\.id))
    }

    @Test("Persiste los modos y usa todos los PRs por defecto o ante valores desconocidos")
    func persistence() throws {
        let suite = "automation-filter-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(AutomationFilter.load(defaults: defaults) == .all)
        defaults.set("unknown", forKey: "github.automationFilter")
        #expect(AutomationFilter.load(defaults: defaults) == .all)
        for filter in AutomationFilter.allCases {
            filter.persist(defaults: defaults)
            let reopened = try #require(UserDefaults(suiteName: suite))
            #expect(AutomationFilter.load(defaults: reopened) == filter)
        }
    }

    private func pr(
        _ id: String, author: Author, repository: String = "org/api",
        checks: CheckState = .success, merge: Bool = false
    ) -> PullRequest {
        PullRequest(
            id: id, number: 1, title: "Cambio", url: URL(string: "https://github.com/\(repository)/pull/1")!,
            repository: repository, baseRefName: "main", headRefName: "change", author: author,
            updatedAt: .now, isDraft: false, checks: checks, reviewDecision: .reviewRequired,
            mergeable: .mergeable, mergeStateStatus: merge ? .clean : nil,
            defaultMergeMethod: .squash, authoredByMe: false, requestedFromMe: true,
            reviewedByMe: false, approvals: 0, approvedByMe: false
        )
    }
}
