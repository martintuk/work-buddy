import Foundation
import Testing

@testable import WorkBuddy

@Suite("Autenticación de ACLI")
struct ACLIStatusTests {
    @Test("Exit exitoso significa sesión activa")
    func authenticated() throws {
        let status = try ACLI.classifyAuthentication(
            exitCode: 0,
            output: "✓ Authenticated\n  Site: example.atlassian.net"
        )
        #expect(status == .authenticated(site: URL(string: "https://example.atlassian.net")))
    }

    @Test("La respuesta unauthorized guía al login externo")
    func signedOut() throws {
        #expect(try ACLI.classifyAuthentication(
            exitCode: 1,
            output: "Error: unauthorized: use 'acli jira auth login' to authenticate"
        ) == .signedOut)
    }

    @Test("Una falla desconocida no se presenta como falta de login")
    func unexpectedFailure() {
        #expect(throws: ACLI.Failure.self) {
            try ACLI.classifyAuthentication(exitCode: 2, output: "network unavailable")
        }
    }
}

@Suite("Cola de SHR")
struct SHRQueueTests {
    @Test("Busca sólo Stakeholder Review asignado a la cuenta activa")
    func query() {
        #expect(SHRQueue.jql.contains("assignee = currentUser()"))
        #expect(SHRQueue.jql.contains("status = \"Stakeholder Review\""))
        #expect(SHRQueue.jql.contains("ORDER BY updated DESC"))
        #expect(SHRQueue.arguments.contains("--paginate"))
        #expect(SHRQueue.arguments.contains("--json"))
    }

    @Test("Decodifica la respuesta JSON de ACLI")
    func decoding() throws {
        let data = Data(#"[{"key":"LABOS-42","fields":{"summary":"Revisar cambio","issuetype":{"name":"Story"}}}]"#.utf8)
        let items = try JSONDecoder().decode([JiraWorkItem].self, from: data)
        let item = try #require(items.first)
        #expect(item.key == "LABOS-42")
        #expect(item.title == "Revisar cambio")
        #expect(item.issueType == "Story")
    }
}
