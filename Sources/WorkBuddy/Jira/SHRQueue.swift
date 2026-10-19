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

    struct QueryFailure: LocalizedError {
        enum Reason { case fieldUnavailable, statusUnavailable, other }

        let reason: Reason
        let underlying: ACLI.Failure

        init(exitCode: Int32, output: String) {
            underlying = .commandFailed(exitCode: exitCode, output: output)
            let message = output.lowercased()
            let unavailable = ["does not exist", "not found", "not searchable", "cannot be searched",
                               "not supported", "permission", "access", "not valid"]
                .contains { message.contains($0) }
            if unavailable && ["field 'stakeholder'", "field \"stakeholder\"", "field stakeholder "]
                .contains(where: { message.contains($0) }) {
                reason = .fieldUnavailable
            } else if unavailable && message.contains("stakeholder review") && message.contains("status") {
                reason = .statusUnavailable
            } else {
                reason = .other
            }
        }

        var errorDescription: String? {
            let key: L10n.Key = switch reason {
            case .fieldUnavailable: .errorSHRFieldUnavailable
            case .statusUnavailable: .errorSHRStatusUnavailable
            case .other: .errorSHRQuery
            }
            return L10n.text(key, underlying.localizedDescription)
        }
    }

    static func fetch(
        command: @Sendable ([String]) async throws -> Data = { try await ACLI.run($0) }
    ) async throws -> [JiraWorkItem] {
        let data: Data
        do {
            data = try await command(arguments)
        } catch ACLI.Failure.commandFailed(let exitCode, let output) {
            throw QueryFailure(exitCode: exitCode, output: output)
        }
        do {
            return try JSONDecoder().decode([JiraWorkItem].self, from: data)
        } catch {
            throw ACLI.Failure.badJSON(String(describing: error))
        }
    }
}
