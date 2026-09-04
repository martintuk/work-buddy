import Testing

@testable import WorkBuddy

@Suite("Autenticación de ACLI")
struct ACLIStatusTests {
    @Test("Exit exitoso significa sesión activa")
    func authenticated() throws {
        #expect(try ACLI.classifyAuthentication(
            exitCode: 0,
            output: "Authenticated as user@example.com"
        ) == .authenticated)
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
