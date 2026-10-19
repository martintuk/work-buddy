import Foundation

/// Both queues share the CLI contract; JQL is a process argument, never shell code.
enum JiraQueue {
    static func arguments(jql: String, limit: Int?) -> [String] {
        ["jira", "workitem", "search", "--jql", jql,
         "--fields", "key,summary,issuetype,status"]
            + (limit.map { ["--limit", String($0)] } ?? ["--paginate"])
            + ["--json"]
    }

    struct QueryFailure: LocalizedError {
        enum Reason { case fieldUnavailable, statusUnavailable, other }
        let reason: Reason
        let title: String
        let underlying: ACLI.Failure

        init(title: String, exitCode: Int32, output: String) {
            self.title = title
            underlying = .commandFailed(exitCode: exitCode, output: output)
            let message = output.lowercased()
            let unavailable = ["does not exist", "not found", "not searchable", "cannot be searched",
                               "not supported", "permission", "access", "not valid"]
                .contains { message.contains($0) }
            if unavailable && ["field 'status'", "field \"status\"", "status does not exist"]
                .contains(where: { message.contains($0) }) {
                reason = .statusUnavailable
            } else if unavailable && message.contains("field") {
                reason = .fieldUnavailable
            } else {
                reason = .other
            }
        }

        var errorDescription: String? {
            let key: L10n.Key = switch reason {
            case .fieldUnavailable: .errorJiraFieldUnavailable
            case .statusUnavailable: .errorJiraStatusUnavailable
            case .other: .errorJiraQuery
            }
            return L10n.text(key, title, underlying.localizedDescription)
        }
    }

    static func fetch(
        jql: String, title: String, limit: Int? = nil,
        command: @Sendable ([String]) async throws -> Data = { try await ACLI.run($0) }
    ) async throws -> [JiraWorkItem] {
        let data: Data
        do {
            data = try await command(arguments(jql: jql, limit: limit))
        } catch ACLI.Failure.commandFailed(let exitCode, let output) {
            throw QueryFailure(title: title, exitCode: exitCode, output: output)
        }
        do {
            return try JSONDecoder().decode([JiraWorkItem].self, from: data)
        } catch {
            throw ACLI.Failure.badJSON(String(describing: error))
        }
    }
}
