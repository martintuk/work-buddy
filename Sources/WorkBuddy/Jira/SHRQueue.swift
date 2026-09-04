import Foundation

/// Tickets asignados a la cuenta activa que esperan Stakeholder Review.
enum SHRQueue {
    static let jql = """
    assignee = currentUser() AND status = "Stakeholder Review" ORDER BY updated DESC
    """

    static let arguments = [
        "jira", "workitem", "search",
        "--jql", jql,
        "--fields", "key,summary,issuetype",
        "--paginate",
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
