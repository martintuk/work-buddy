import Foundation

/// Valores que dependen del entorno GitHub de cada persona.
///
/// Son identificadores, no secretos: la autenticación sigue perteneciendo a
/// `gh`. Se persisten en UserDefaults para que la app no necesite constantes de
/// una organización concreta.
struct AppConfiguration: Equatable, Sendable {
    enum ValidationError: LocalizedError {
        case invalidOrganization(String)
        case invalidMachineAccount(String)

        var errorDescription: String? {
            switch self {
            case .invalidOrganization(let value):
                "La organización `\(value)` no parece un identificador válido de GitHub."
            case .invalidMachineAccount(let value):
                "La cuenta `\(value)` no parece un login válido de GitHub."
            }
        }
    }

    private enum Key {
        static let organization = "configuration.organization" // Preferencia anterior.
        static let organizations = "configuration.organizations"
        static let machineAccounts = "configuration.machineAccounts"
    }

    static let empty = AppConfiguration(organizations: [], machineAccounts: [])

    let organizations: Set<String>
    let machineAccounts: Set<String>

    var machineAccountsText: String { machineAccounts.sorted().joined(separator: ", ") }

    private init(organizations: Set<String>, machineAccounts: Set<String>) {
        self.organizations = organizations
        self.machineAccounts = machineAccounts
    }

    init(organizations: Set<String>, machineAccountsText: String) throws {
        var normalized: Set<String> = []
        for value in organizations {
            let organization = Self.strippingAt(value)
            guard Self.isValidGitHubLogin(organization) else {
                throw ValidationError.invalidOrganization(organization)
            }
            normalized.insert(organization.lowercased())
        }
        self.organizations = normalized

        let rawAccounts = machineAccountsText.components(
            separatedBy: CharacterSet(charactersIn: ",;\n\t ")
        ).filter { !$0.isEmpty }

        var accounts: Set<String> = []
        for rawAccount in rawAccounts {
            let account = Self.strippingAt(rawAccount)
            guard Self.isValidGitHubLogin(account) else {
                throw ValidationError.invalidMachineAccount(account)
            }
            accounts.insert(account.lowercased())
        }
        machineAccounts = accounts
    }

    /// Agrega el alcance a una búsqueda de GitHub. El valor ya fue validado y
    /// no puede cerrar las comillas de la query GraphQL que lo contiene.
    func scopedSearch(_ search: String) -> String {
        guard !organizations.isEmpty else { return search }
        // Las queries usan type: ISSUE (búsqueda clásica), donde varios org:
        // se combinan con OR. ISSUE_ADVANCED requiere otra sintaxis.
        return search + " " + organizations.sorted().map { "org:\($0)" }.joined(separator: " ")
    }

    func persist(defaults: UserDefaults = .standard) {
        defaults.set(organizations.sorted(), forKey: Key.organizations)
        defaults.removeObject(forKey: Key.organization)
        defaults.set(machineAccounts.sorted(), forKey: Key.machineAccounts)
    }

    static func load(defaults: UserDefaults = .standard) -> AppConfiguration {
        let storedOrganizations: [String]
        if let selected = defaults.stringArray(forKey: Key.organizations) {
            storedOrganizations = selected
        } else if let legacy = defaults.string(forKey: Key.organization),
                  !legacy.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            storedOrganizations = [legacy]
        } else {
            storedOrganizations = []
        }
        let storedAccounts = defaults.stringArray(forKey: Key.machineAccounts) ?? []

        // Si una versión futura cambia la validación, un valor viejo inválido
        // no debe impedir que la aplicación arranque.
        return (try? AppConfiguration(
            organizations: Set(storedOrganizations),
            machineAccountsText: storedAccounts.joined(separator: ",")
        )) ?? .empty
    }

    private static func strippingAt(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("@") ? String(trimmed.dropFirst()) : trimmed
    }

    private static func isValidGitHubLogin(_ value: String) -> Bool {
        value.range(
            of: #"^[A-Za-z0-9](?:[A-Za-z0-9-]{0,37}[A-Za-z0-9])?$"#,
            options: .regularExpression
        ) != nil
    }
}
