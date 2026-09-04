import Foundation

/// El subconjunto de un work item de Jira que necesita el panel.
struct JiraWorkItem: Decodable, Equatable, Identifiable, Sendable {
    let key: String
    let fields: Fields

    var id: String { key }
    var title: String { fields.summary }
    var issueType: String { fields.issuetype.name }

    struct Fields: Decodable, Equatable, Sendable {
        let summary: String
        let issuetype: IssueType
    }

    struct IssueType: Decodable, Equatable, Sendable {
        let name: String
    }
}
