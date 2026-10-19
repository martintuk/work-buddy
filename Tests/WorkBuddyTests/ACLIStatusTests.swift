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

@Suite("Consultas configurables de Jira")
struct JiraQueueTests {
    @Test("JQL configurable se pasa como un único argumento, sin interpolar shell")
    func query() {
        let query = #"project = TEAM AND "Custom Field" = currentUser() ORDER BY updated DESC"#
        let args = JiraQueue.arguments(jql: query, limit: nil)
        #expect(args[4] == query)
        #expect(args.contains("--paginate"))
        #expect(args.contains("--json"))
        #expect(args.contains("key,summary,issuetype,status"))
        let recent = JiraQueue.arguments(jql: JiraConfiguration.defaultRecentJQL, limit: 10)
        #expect(recent.contains("--limit"))
        #expect(recent.contains("10"))
        #expect(!recent.contains("--paginate"))
    }

    @Test("Los errores de configuración identifican el campo o estado sin ocultar el detalle", arguments: [
        ("Field 'Stakeholder' does not exist or you do not have permission to view it.", JiraQueue.QueryFailure.Reason.fieldUnavailable),
        ("Field \"Reviewers\" is not searchable.", .fieldUnavailable),
        ("Field 'Stakeholder' does not exist. Query: " + JiraConfiguration.defaultPrimaryJQL, .fieldUnavailable),
        ("The value 'Stakeholder Review' does not exist for the field 'status'.", .statusUnavailable),
        ("Could not resolve host example.atlassian.net", .other),
        ("Forbidden: insufficient permissions", .other),
        ("Invalid JQL syntax: " + JiraConfiguration.defaultPrimaryJQL, .other),
    ])
    func queryErrors(output: String, reason: JiraQueue.QueryFailure.Reason) async throws {
        do {
            _ = try await JiraQueue.fetch(jql: JiraConfiguration.defaultPrimaryJQL, title: "My queue") { arguments in
                #expect(arguments == JiraQueue.arguments(jql: JiraConfiguration.defaultPrimaryJQL, limit: nil))
                throw ACLI.Failure.commandFailed(exitCode: 2, output: output)
            }
            Issue.record("Expected query failure")
        } catch let error as JiraQueue.QueryFailure {
            #expect(error.reason == reason)
            #expect(Diagnostics.Failure(error).category == Diagnostics.Failure(error.underlying).category)
            #expect(Diagnostics.Failure(error).exitCode == 2)
            for language in [AppLanguage.spanish, .english] {
                let message = L10n.$renderLanguage.withValue(language) { error.localizedDescription }
                #expect(message.contains(output))
                #expect(message.contains("2"))
                #expect(!message.contains("%@"))
            }
        }
    }

    @Test("Instalación y autenticación conservan los estados que reconoce JiraStore")
    func authenticationErrors() async throws {
        for failure in [ACLI.Failure.notInstalled, .notAuthenticated] {
            do {
                _ = try await JiraQueue.fetch(jql: JiraConfiguration.defaultPrimaryJQL, title: "My queue") { _ in throw failure }
                Issue.record("Expected authentication failure")
            } catch let error as ACLI.Failure {
                switch (failure, error) {
                case (.notInstalled, .notInstalled), (.notAuthenticated, .notAuthenticated): break
                default: Issue.record("Authentication error was changed")
                }
            }
        }
    }

    @Test("Cancelación y respuestas inválidas no se atribuyen al campo Stakeholder")
    func otherErrors() async {
        await #expect(throws: CancellationError.self) {
            _ = try await JiraQueue.fetch(jql: JiraConfiguration.defaultPrimaryJQL, title: "My queue") { _ in throw CancellationError() }
        }
        do {
            _ = try await JiraQueue.fetch(jql: JiraConfiguration.defaultPrimaryJQL, title: "My queue") { _ in Data("not JSON".utf8) }
            Issue.record("Expected decoding failure")
        } catch ACLI.Failure.badJSON { }
        catch { Issue.record("Unexpected failure: \(error)") }
    }

    @Test("Una consulta válida mantiene los tickets y una respuesta vacía sigue siendo válida")
    func successfulFetch() async throws {
        let items = try await JiraQueue.fetch(jql: JiraConfiguration.defaultPrimaryJQL, title: "My queue") { _ in
            Data(#"[{"key":"LABOS-42","fields":{"summary":"Revisar cambio","issuetype":{"name":"Story"}}}]"#.utf8)
        }
        #expect(items.map(\.key) == ["LABOS-42"])
        let empty = try await JiraQueue.fetch(jql: JiraConfiguration.defaultPrimaryJQL, title: "My queue") { _ in Data("[]".utf8) }
        #expect(empty.isEmpty)
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
