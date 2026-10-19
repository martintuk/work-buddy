import Foundation
import Testing

@testable import WorkBuddy

@Suite("Configuration")
struct AppConfigurationTests {
    @Test("Normalize organizations and machine accounts")
    func normalization() throws {
        let configuration = try AppConfiguration(
            organizations: [" @Example-Org "],
            machineAccountsText: "CI-User, release-user  @CI-User"
        )

        #expect(configuration.organizations == ["example-org"])
        #expect(configuration.machineAccounts == ["ci-user", "release-user"])
        #expect(configuration.scopedSearch("is:pr") == "is:pr org:example-org")
    }

    @Test("Reject values that could break the query")
    func validation() {
        #expect(throws: AppConfiguration.ValidationError.self) {
            try AppConfiguration(
                organizations: ["example-org\" archived:true"],
                machineAccountsText: ""
            )
        }
        #expect(throws: AppConfiguration.ValidationError.self) {
            try AppConfiguration(
                organizations: [],
                machineAccountsText: "ci-user, usuario_invalido"
            )
        }
    }

    @Test("Persist without organization-specific defaults")
    func persistence() throws {
        let suiteName = "configuration-test-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let configuration = try AppConfiguration(
            organizations: ["example-org"],
            machineAccountsText: "ci-user, release-user"
        )
        configuration.persist(defaults: defaults)

        #expect(AppConfiguration.load(defaults: defaults) == configuration)
        #expect(AppConfiguration.empty.machineAccounts.isEmpty)
        #expect(AppConfiguration.empty.organizations.isEmpty)
    }
    @Test("Normalize and persist multiple organizations together")
    func multipleSelection() throws {
        let configuration = try AppConfiguration(
            organizations: ["Beta", "alpha", "ALPHA"], machineAccountsText: ""
        )
        #expect(configuration.organizations == ["alpha", "beta"])
        #expect(configuration.scopedSearch("is:pr") == "is:pr org:alpha org:beta")
        let defaults = try #require(UserDefaults(suiteName: "multi-org-\(UUID())"))
        configuration.persist(defaults: defaults)
        defer { defaults.removeObject(forKey: "configuration.organizations") }
        #expect(AppConfiguration.load(defaults: defaults) == configuration)
    }

    @Test("Migrate the previous organization and allow clearing the selection")
    func migration() throws {
        let suite = "migration-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("Old-Org", forKey: "configuration.organization")
        defaults.set(["ci-user"], forKey: "configuration.machineAccounts")
        let migrated = AppConfiguration.load(defaults: defaults)
        #expect(migrated.organizations == ["old-org"])
        #expect(migrated.machineAccounts == ["ci-user"])
        migrated.persist(defaults: defaults)
        #expect(defaults.object(forKey: "configuration.organization") == nil)
        AppConfiguration.empty.persist(defaults: defaults)
        #expect(AppConfiguration.load(defaults: defaults).organizations.isEmpty)
        #expect(AppConfiguration.load(defaults: defaults).scopedSearch("is:pr") == "is:pr")
    }

    @Test("Read all organization pages without duplicates")
    func organizationPages() throws {
        let data = Data(#"[[{"login":"Beta"}],[{"login":"Alpha"},{"login":"beta"}]]"#.utf8)
        #expect(try GitHubOrganizations.decode(data) == ["alpha", "beta"])
        #expect(try GitHubOrganizations.decode(Data("[[]]".utf8)).isEmpty)
        #expect(throws: GH.Failure.self) {
            try GitHubOrganizations.decode(Data(#"{"message":"error"}"#.utf8))
        }
    }

}
