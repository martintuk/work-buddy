import Foundation
import Testing
@testable import WorkBuddy

@Suite("Experimental Jira configuration")
struct JiraConfigurationTests {
    @Test("Fresh installations start disabled with generic queries")
    func defaults() throws {
        let defaults = try #require(UserDefaults(suiteName: "jira-defaults-\(UUID())"))
        let config = JiraConfiguration.load(defaults: defaults)
        #expect(!config.isEnabled)
        #expect(config.primaryJQL.contains("assignee = currentUser()"))
        #expect(config.recentJQL.contains("creator = currentUser()"))
        #expect(!config.primaryJQL.contains("Stakeholder"))
    }

    @Test("Save user queries without depending on a team")
    func persistence() throws {
        let suite = "jira-persistence-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var config = JiraConfiguration()
        config.isEnabled = true
        config.primaryJQL = #" "Reviewers" = currentUser() AND status = "In Review" "#
        config.recentJQL = "project = ABC ORDER BY created DESC"
        try config.persist(defaults: defaults)
        let loaded = JiraConfiguration.load(defaults: defaults)
        #expect(loaded == (try config.validated()))
        #expect(loaded.recentJQL == config.recentJQL)
    }

    @Test("Legacy preferences retain queries and discard custom names")
    func legacyNames() throws {
        let suite = "jira-legacy-names-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let data = Data(#"{"isEnabled":true,"primaryName":"Custom review","primaryJQL":"project = ABC","recentName":"Custom recent","recentJQL":"creator = currentUser()"}"#.utf8)
        defaults.set(data, forKey: JiraConfiguration.preferenceKey)
        let loaded = JiraConfiguration.load(defaults: defaults)
        #expect(loaded.isEnabled)
        #expect(loaded.primaryJQL == "project = ABC")
        #expect(loaded.recentJQL == "creator = currentUser()")
        #expect(loaded.primaryTitle == "Assigned to me")
        #expect(loaded.recentTitle == "Recently created")
        try loaded.persist(defaults: defaults)
        let saved = try #require(defaults.data(forKey: JiraConfiguration.preferenceKey))
        let fields = try #require(JSONSerialization.jsonObject(with: saved) as? [String: Any])
        #expect(fields["primaryName"] == nil && fields["recentName"] == nil)
    }

    @Test("Empty queries do not replace valid configuration")
    func emptyQuery() throws {
        var config = JiraConfiguration()
        config.primaryJQL = " \n "
        #expect(throws: JiraConfiguration.ValidationError.self) { try config.validated() }
        config = JiraConfiguration()
        config.recentJQL = ""
        #expect(throws: JiraConfiguration.ValidationError.self) { try config.validated() }
    }

    @Test("Corrupt preferences never enable Jira automatically")
    func corruptPreferences() throws {
        let suite = "jira-corrupt-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(Data("invalid JSON".utf8), forKey: JiraConfiguration.preferenceKey)
        #expect(!JiraConfiguration.load(defaults: defaults).isEnabled)
    }
}

@Suite("Experimental Jira lifecycle")
@MainActor
struct JiraStoreTests {
    @Test("Disabled Jira neither authenticates nor queries when the scheduler refreshes")
    func disabled() async throws {
        let suite = "jira-disabled-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = JiraStore(defaults: defaults, authenticate: {
            Issue.record("Disabled Jira must not authenticate")
            return .signedOut
        }, loadQueue: { _, _, _ in
            Issue.record("Disabled Jira must not query")
            return []
        })
        store.refresh()
        store.refresh()
        try store.setEnabled(true)
        try store.setEnabled(false)
        await Task.yield()
        #expect(!store.isEnabled)
        #expect(!store.isChecking)
        #expect(store.siteURL == nil)
    }

    @Test("Enabling loads data; disabling clears data and retains saved queries")
    func toggling() async throws {
        let suite = "jira-toggle-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let calls = QueryCalls()
        let store = JiraStore(defaults: defaults, authenticate: {
            .authenticated(site: URL(string: "https://example.atlassian.net"))
        }, loadQueue: { query, title, limit in
            await calls.record(query, title, limit)
            return [jiraItem(limit == nil ? "ABC-1" : "ABC-2")]
        })
        var config = store.configuration
        config.primaryJQL = "project = ABC ORDER BY updated DESC"
        try store.configure(config)
        #expect(await calls.count == 0)
        try store.setEnabled(true)
        try await waitFor { !store.isChecking }
        #expect(store.primaryItems.map(\.key) == ["ABC-1"])
        #expect(store.recentlyCreatedItems.map(\.key) == ["ABC-2"])
        #expect(await calls.queries.contains(config.primaryJQL))
        #expect(store.url(for: jiraItem("ABC-1"))?.absoluteString == "https://example.atlassian.net/browse/ABC-1")
        try store.setEnabled(false)
        store.refresh()
        #expect(!store.isChecking)
        #expect(store.primaryItems.isEmpty && store.recentlyCreatedItems.isEmpty)
        #expect(store.siteURL == nil && store.lastUpdated == nil)
        #expect(await calls.count == 2)
        let restored = JiraStore(defaults: defaults)
        #expect(!restored.isEnabled)
        #expect(restored.configuration.primaryJQL == config.primaryJQL)
        try store.setEnabled(true)
        try await waitFor { !store.isChecking }
        #expect(await calls.count == 4)
    }

    @Test("Authentication completing after disabling Jira starts no searches")
    func disabledDuringAuth() async throws {
        let suite = "jira-auth-race-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let gate = AuthGate()
        let store = JiraStore(defaults: defaults, authenticate: { await gate.wait() }, loadQueue: { _, _, _ in
            Issue.record("Stale authentication must not start a query")
            return []
        })
        try store.setEnabled(true)
        try await waitFor { await gate.started }
        try store.setEnabled(false)
        await gate.finish()
        try await Task.sleep(for: .milliseconds(30))
        #expect(store.siteURL == nil)
        #expect(!store.isChecking)
        if case .idle = store.state {} else { Issue.record("Expected idle state") }
    }

    @Test("Late results and errors do not reactivate Jira", arguments: [false, true])
    func disabledDuringQuery(fails: Bool) async throws {
        let suite = "jira-query-race-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let gate = QueryGate()
        let store = JiraStore(defaults: defaults, authenticate: {
            .authenticated(site: URL(string: "https://example.atlassian.net"))
        }, loadQueue: { _, _, _ in try await gate.wait() })
        try store.setEnabled(true)
        try await waitFor { await gate.count == 2 }
        try store.setEnabled(false)
        await gate.finish(fails: fails)
        try await Task.sleep(for: .milliseconds(30))
        #expect(store.primaryItems.isEmpty && store.recentlyCreatedItems.isEmpty)
        #expect(store.siteURL == nil && store.lastUpdated == nil)
        if case .idle = store.state {} else { Issue.record("Late completion changed disabled state") }
    }

    @Test("Changing JQL discards the old load even if it finishes after the new one")
    func changedQuery() async throws {
        let suite = "jira-config-race-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let gate = QueryGate()
        let store = JiraStore(defaults: defaults, authenticate: {
            .authenticated(site: URL(string: "https://example.atlassian.net"))
        }, loadQueue: { query, _, _ in
            if query == JiraConfiguration.defaultPrimaryJQL { return try await gate.wait() }
            return [jiraItem("NEW-1")]
        })
        try store.setEnabled(true)
        try await waitFor { await gate.count == 1 }
        var updated = store.configuration
        updated.primaryJQL = "project = NEW"
        try store.configure(updated)
        try await waitFor { !store.isChecking }
        #expect(store.primaryItems.map(\.key) == ["NEW-1"])
        await gate.finish(fails: false)
        try await Task.sleep(for: .milliseconds(30))
        #expect(store.primaryItems.map(\.key) == ["NEW-1"])
        if case .loaded = store.state {} else { Issue.record("Stale completion changed state") }
    }

    private func waitFor(_ condition: @MainActor () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !(await condition()), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(await condition())
    }
}

private func jiraItem(_ key: String) -> JiraWorkItem {
    JiraWorkItem(key: key, fields: .init(summary: "Example ticket", issuetype: .init(name: "Task"), status: .init(name: "Open")))
}

private actor QueryCalls {
    var queries: [String] = []
    var count: Int { queries.count }
    func record(_ query: String, _ title: String, _ limit: Int?) { queries.append(query) }
}

private actor AuthGate {
    var started = false
    private var continuation: CheckedContinuation<ACLI.AuthenticationStatus, Never>?
    func wait() async -> ACLI.AuthenticationStatus {
        await withCheckedContinuation { continuation = $0; started = true }
    }
    func finish() {
        continuation?.resume(returning: .authenticated(site: URL(string: "https://example.atlassian.net")))
        continuation = nil
    }
}

private actor QueryGate {
    private var continuations: [CheckedContinuation<[JiraWorkItem], Error>] = []
    var count: Int { continuations.count }
    func wait() async throws -> [JiraWorkItem] {
        try await withCheckedThrowingContinuation { continuations.append($0) }
    }
    func finish(fails: Bool) {
        for continuation in continuations {
            if fails { continuation.resume(throwing: ACLI.Failure.commandFailed(exitCode: 1, output: "late failure")) }
            else { continuation.resume(returning: [jiraItem("OLD-1")]) }
        }
        continuations = []
    }
}
