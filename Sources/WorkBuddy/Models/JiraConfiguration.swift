import Foundation

/// Opt-in explícito, sin depender de campos ni estados de un equipo particular.
struct JiraConfiguration: Codable, Equatable, Sendable {
    static let preferenceKey = "jira.configuration"
    static let defaultPrimaryJQL = "assignee = currentUser() AND statusCategory != Done ORDER BY updated DESC"
    static let defaultRecentJQL = "creator = currentUser() ORDER BY created DESC"

    var isEnabled = false
    var primaryName = ""
    var primaryJQL = defaultPrimaryJQL
    var recentName = ""
    var recentJQL = defaultRecentJQL

    var primaryTitle: String { primaryName.isEmpty ? L10n.text(.jiraAssignedToMe) : primaryName }
    var recentTitle: String { recentName.isEmpty ? L10n.text(.jiraRecentlyCreated) : recentName }

    enum ValidationError: LocalizedError {
        case emptyQuery
        var errorDescription: String? { L10n.text(.errorJiraEmptyQuery) }
    }

    func validated() throws -> Self {
        var result = self
        result.primaryName = primaryName.trimmingCharacters(in: .whitespacesAndNewlines)
        result.recentName = recentName.trimmingCharacters(in: .whitespacesAndNewlines)
        result.primaryJQL = primaryJQL.trimmingCharacters(in: .whitespacesAndNewlines)
        result.recentJQL = recentJQL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.primaryJQL.isEmpty, !result.recentJQL.isEmpty else { throw ValidationError.emptyQuery }
        return result
    }

    func persist(defaults: UserDefaults) throws {
        defaults.set(try JSONEncoder().encode(validated()), forKey: Self.preferenceKey)
    }

    static func load(defaults: UserDefaults = .standard) -> Self {
        guard let data = defaults.data(forKey: preferenceKey),
              let value = try? JSONDecoder().decode(Self.self, from: data),
              let valid = try? value.validated() else { return Self() }
        return valid
    }
}
