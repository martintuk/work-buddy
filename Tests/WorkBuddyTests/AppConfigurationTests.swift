import Foundation
import Testing

@testable import WorkBuddy

@Suite("Configuración")
struct AppConfigurationTests {
    @Test("Normaliza organización y cuentas de máquina")
    func normalizacion() throws {
        let configuration = try AppConfiguration(
            organizationText: " @Example-Org ",
            machineAccountsText: "CI-User, release-user  @CI-User"
        )

        #expect(configuration.organization == "example-org")
        #expect(configuration.machineAccounts == ["ci-user", "release-user"])
        #expect(configuration.scopedSearch("is:pr") == "is:pr org:example-org")
    }

    @Test("Rechaza valores que podrían romper la query")
    func validacion() {
        #expect(throws: AppConfiguration.ValidationError.self) {
            try AppConfiguration(
                organizationText: "example-org\" archived:true",
                machineAccountsText: ""
            )
        }
        #expect(throws: AppConfiguration.ValidationError.self) {
            try AppConfiguration(
                organizationText: "",
                machineAccountsText: "ci-user, usuario_invalido"
            )
        }
    }

    @Test("Persiste sin valores predeterminados de una organización")
    func persistencia() throws {
        let suiteName = "configuration-test-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let configuration = try AppConfiguration(
            organizationText: "example-org",
            machineAccountsText: "ci-user, release-user"
        )
        configuration.persist(defaults: defaults)

        #expect(AppConfiguration.load(defaults: defaults) == configuration)
        #expect(AppConfiguration.empty.machineAccounts.isEmpty)
        #expect(AppConfiguration.empty.organization == nil)
    }
}
