import Foundation
import Testing

@testable import WorkBuddy

@Suite("Local notes")
@MainActor
struct LocalNoteStoreTests {
    @Test("Save every edit and preserve plain text after restarting")
    func persistence() throws {
        let suite = "local-notes-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let id = LocalNoteID.github(nodeID: "PR_123", host: "github.com")
        let store = LocalNoteStore(defaults: defaults)
        #expect(store.text(for: id).isEmpty)
        let text = "  Remember tomorrow 📝\n- without **formatting**\nhttps://example.com\n"
        store.setText(text, for: id)
        #expect(LocalNoteStore(defaults: defaults).text(for: id) == text)
        store.setText("Una sola nota actualizada", for: id)
        #expect(LocalNoteStore(defaults: defaults).text(for: id) == "Una sola nota actualizada")
    }

    @Test("Deleting notes leaves other items and preferences unchanged")
    func deletionAndIsolation() throws {
        let suite = "local-notes-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("es", forKey: "appearance.language")
        let github = LocalNoteID.github(nodeID: "PR_123", host: "github.com")
        let other = LocalNoteID.github(nodeID: "PR_456", host: "github.com")
        let jira = LocalNoteID.jira(key: "APP-1", site: URL(string: "https://team.atlassian.net")!)
        let store = LocalNoteStore(defaults: defaults)
        store.setText("GitHub", for: github)
        store.setText("Otro PR", for: other)
        store.setText("Jira", for: jira)
        store.setText("", for: github)
        let restored = LocalNoteStore(defaults: defaults)
        #expect(restored.text(for: github).isEmpty)
        #expect(restored.text(for: other) == "Otro PR")
        #expect(restored.text(for: jira) == "Jira")
        #expect(defaults.string(forKey: "appearance.language") == "es")
    }

    @Test("Stable identities separated by provider and site")
    func identities() {
        let site = URL(string: "https://team.atlassian.net")!
        let jira = LocalNoteID.jira(key: "APP-1", site: site)
        #expect(jira == .jira(key: "app-1", site: URL(string: "https://TEAM.atlassian.net/")!))
        #expect(jira != .jira(key: "APP-1", site: URL(string: "https://other.atlassian.net")!))
        #expect(jira != .jira(key: "APP-1", site: site.appending(path: "another-jira")))
        #expect(jira != .github(nodeID: "APP-1", host: "team.atlassian.net"))
        #expect(LocalNoteID.github(nodeID: "PR_1", host: "GITHUB.COM") == .github(nodeID: "PR_1", host: "github.com"))
        #expect(LocalNoteID.github(nodeID: "PR_1", host: "github.com") != .github(nodeID: "PR_1", host: "github.internal"))
    }
}
