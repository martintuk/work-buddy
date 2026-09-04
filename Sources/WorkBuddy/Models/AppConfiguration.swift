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
        static let organization = "configuration.organization"
        static let machineAccounts = "configuration.machineAccounts"
    }

    static let empty = AppConfiguration(organization: nil, machineAccounts: [])

    let organization: String?
    let machineAccounts: Set<String>

    var organizationText: String { organization ?? "" }
    var machineAccountsText: String { machineAccounts.sorted().joined(separator: ", ") }

    private init(organization: String?, machineAccounts: Set<String>) {
        self.organization = organization
        self.machineAccounts = machineAccounts
    }

    init(organizationText: String, machineAccountsText: String) throws {
        let rawOrganization = Self.strippingAt(organizationText)
        if rawOrganization.isEmpty {
            organization = nil
        } else if Self.isValidGitHubLogin(rawOrganization) {
            organization = rawOrganization.lowercased()
        } else {
            throw ValidationError.invalidOrganization(rawOrganization)
        }

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
        guard let organization else { return search }
        return "\(search) org:\(organization)"
    }

    func persist(defaults: UserDefaults = .standard) {
        defaults.set(organization, forKey: Key.organization)
        defaults.set(machineAccounts.sorted(), forKey: Key.machineAccounts)
    }

    static func load(defaults: UserDefaults = .standard) -> AppConfiguration {
        let storedOrganization = defaults.string(forKey: Key.organization) ?? ""
        let storedAccounts = defaults.stringArray(forKey: Key.machineAccounts) ?? []

        // Si una versión futura cambia la validación, un valor viejo inválido
        // no debe impedir que la aplicación arranque.
        return (try? AppConfiguration(
            organizationText: storedOrganization,
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
