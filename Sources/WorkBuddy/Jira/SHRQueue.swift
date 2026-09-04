import Foundation

/// Tickets donde la cuenta activa figura como Stakeholder y esperan su review.
enum SHRQueue {
    static let jql = """
    "Stakeholder" = currentUser() AND status = "Stakeholder Review" ORDER BY updated DESC
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
