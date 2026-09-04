import Foundation

/// Los últimos tickets creados por la cuenta activa.
enum RecentlyCreatedQueue {
    static let limit = 10
    static let jql = "creator = currentUser() ORDER BY created DESC"

    static let arguments = [
        "jira", "workitem", "search",
        "--jql", jql,
        "--fields", "key,summary,issuetype",
        "--limit", String(limit),
        "--json"
    ]

    static func fetch() async throws -> [JiraWorkItem] {
        let data = try await ACLI.run(arguments)
        do {
            return try JSONDecoder().decode([JiraWorkItem].self, from: data)
        } catch {
            throw ACLI.Failure.badJSON(String(describing: error))
        }
    }
}
