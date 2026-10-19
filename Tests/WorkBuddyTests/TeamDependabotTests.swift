import Foundation
import Testing
@testable import WorkBuddy

@Suite("Team Dependabot")
struct TeamDependabotTests {
    @Test("General ownership handles comments, case, and the last global rule")
    func ownership() {
        let identities: Set<String> = ["@org/team", "@me"]
        #expect(TeamDependabot.hasGeneralOwnership("* @ORG/TEAM # comentario", identities: identities))
        #expect(TeamDependabot.hasGeneralOwnership("* @me\n/docs/ @other", identities: identities))
        #expect(!TeamDependabot.hasGeneralOwnership("# * @me\n/folder/ @org/team", identities: identities))
        #expect(!TeamDependabot.hasGeneralOwnership("* @org/team\n* @other", identities: identities))
        #expect(!TeamDependabot.hasGeneralOwnership("* @org/team\n*", identities: identities))
        #expect(!TeamDependabot.hasGeneralOwnership("* @org/team-other", identities: identities))
    }

    @Test("The preference persists, respects organizations, and starts disabled")
    func configuration() throws {
        let suite = "teams-config-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(!AppConfiguration.load(defaults: defaults).teamDependabotEnabled)
        let config = try AppConfiguration(
            organizations: ["ORG"], machineAccountsText: "ci-bot",
            teamDependabotEnabled: true, dependabotTeams: [" @Org/Team ", "other/team"]
        )
        #expect(config.effectiveDependabotTeams == ["org/team"])
        config.persist(defaults: defaults)
        #expect(AppConfiguration.load(defaults: defaults) == config)
        var disabled = config
        disabled.teamDependabotEnabled = false
        #expect(disabled.effectiveDependabotTeams.isEmpty)
        #expect(disabled.dependabotTeams == ["org/team", "other/team"])
        #expect(throws: AppConfiguration.ValidationError.self) {
            try AppConfiguration(organizations: [], machineAccountsText: "", dependabotTeams: ["org/../all"])
        }
    }

    @Test("Read paginated teams and deduplicate by organization and slug")
    func teams() throws {
        let data = Data(#"[[{"slug":"Team","organization":{"login":"ORG"}}],[{"slug":"team","organization":{"login":"org"}},{"slug":"team","organization":{"login":"other"}}]]"#.utf8)
        #expect(try GitHubTeams.decode(data) == ["org/team", "other/team"])
    }

    @Test("Discover repositories without duplicates, skip archived ones, and respect CODEOWNERS precedence")
    func discovery() async throws {
        let fixture = DiscoveryFixture()
        let repos = try await TeamDependabot.discover(teams: ["org/a", "org/b"], login: "me") {
            try await fixture.request($0)
        }
        #expect(repos == ["org/owned"])
        #expect(await fixture.reads == 5) // Two teams plus three unique non-archived repositories.
    }

    @Test("GraphQL errors do not become repositories without CODEOWNERS")
    func partialFailure() async {
        await #expect(throws: GH.Failure.self) {
            try await TeamDependabot.discover(teams: ["org/a"], login: "me") { args in
                if args[1] == "graphql" {
                    return Data(#"{"data":{"repository":null},"errors":[{"message":"denied"}]}"#.utf8)
                }
                return Data(#"[[{"full_name":"org/repo","default_branch":"main","archived":false}]]"#.utf8)
            }
        }
    }

    @Test("Daily persistent cache is isolated by account and teams and retained on failure")
    func cache() async throws {
        let suite = "teams-cache-\(UUID())"
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let cache = TeamDependabotCache(suite: suite)
        let now = Date(timeIntervalSince1970: 1_000_000)
        let initial = try await cache.resolve(teams: ["org/a"], login: "me", now: now) { _, _ in ["org/owned"] }
        #expect(initial.repositories == ["org/owned"])
        let reopened = TeamDependabotCache(suite: suite)
        let cached = try await reopened.resolve(teams: ["org/a"], login: "me", now: now.addingTimeInterval(60)) { _, _ in
            Issue.record("Must not query while the cache is current")
            return []
        }
        #expect(cached.repositories == ["org/owned"])
        let stale = try await cache.resolve(teams: ["org/a"], login: "me", now: now.addingTimeInterval(86_401)) { _, _ in
            throw GH.Failure.noAttempts
        }
        #expect(stale.repositories == ["org/owned"])
        #expect(stale.error != nil)
        for (teams, login) in [(["org/b"], "me"), (["org/a"], "other")] {
            let isolated = try await cache.resolve(teams: teams, login: login, now: now) { _, _ in
                throw GH.Failure.noAttempts
            }
            #expect(isolated.repositories.isEmpty)
            #expect(isolated.error != nil)
        }
        let refreshed = try await cache.resolve(teams: ["org/a"], login: "me", force: true, now: now) { _, _ in [] }
        #expect(refreshed.repositories.isEmpty)
        #expect(refreshed.error == nil)
        let disabled = try await cache.resolve(teams: [], login: "me") { _, _ in
            Issue.record("Must not discover without teams")
            return ["org/owned"]
        }
        #expect(disabled.repositories.isEmpty)
    }

    @Test("Canceled discovery does not replace the last valid list")
    func cancelledDiscovery() async throws {
        let suite = "teams-cancel-\(UUID())"
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let cache = TeamDependabotCache(suite: suite)
        _ = try await cache.resolve(teams: ["org/a"], login: "me") { _, _ in ["org/owned"] }
        await #expect(throws: CancellationError.self) {
            try await cache.resolve(teams: ["org/a"], login: "me", force: true) { _, _ in
                throw CancellationError()
            }
        }
        let result = try await cache.resolve(teams: ["org/a"], login: "me") { _, _ in [] }
        #expect(result.repositories == ["org/owned"])
    }

    @Test("Expanded searches use explicit repositories and split queries without losing scope")
    func searches() {
        #expect(TeamDependabot.searches(repositories: []).isEmpty)
        let repos = (1...38).map { "org/repository-\($0)" }
        let searches = TeamDependabot.searches(repositories: repos + repos)
        #expect(searches.count > 1)
        for query in searches {
            #expect(query.count <= 240)
            #expect(!query.contains("review-requested:"))
            #expect(!query.contains(" org:"))
            #expect(query.contains("author:app/dependabot"))
        }
        let found = searches.flatMap { $0.split(separator: " ").filter { $0.hasPrefix("repo:") }.map { String($0.dropFirst(5)) } }
        #expect(found.count == 38)
        #expect(Set(found) == Set(repos))
    }
}

private actor DiscoveryFixture {
    var reads = 0
    func request(_ args: [String]) throws -> Data {
        reads += 1
        if args[1] != "graphql" {
            return Data(#"[[{"full_name":"org/owned","default_branch":"main","archived":false},{"full_name":"org/archived","default_branch":"main","archived":true}],[{"full_name":"org/partial","default_branch":"main","archived":false},{"full_name":"org/precedence","default_branch":"main","archived":false}]]"#.utf8)
        }
        if args.contains("name=owned") {
            return Data(#"{"data":{"repository":{"primary":null,"root":{"text":"* @org/a"},"docs":null}}}"#.utf8)
        }
        if args.contains("name=partial") {
            return Data(#"{"data":{"repository":{"primary":{"text":"/folder/ @org/a"},"root":null,"docs":null}}}"#.utf8)
        }
        return Data(#"{"data":{"repository":{"primary":{"text":"* @other"},"root":{"text":"* @org/a"},"docs":null}}}"#.utf8)
    }
}
