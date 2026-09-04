import Foundation

/// Invoca el CLI oficial de Atlassian sin heredar supuestos del shell.
///
/// La app sólo consulta el estado de autenticación. El login sigue ocurriendo
/// en Terminal, así work-buddy nunca recibe credenciales de Jira.
enum ACLI {
    enum AuthenticationStatus: Equatable, Sendable {
        case authenticated
        case signedOut
    }

    enum Failure: LocalizedError {
        case notInstalled
        case commandFailed(exitCode: Int32, output: String)

        var errorDescription: String? {
            switch self {
            case .notInstalled:
                "No encontré el CLI `acli`."
            case .commandFailed(let exitCode, let output):
                "`acli` falló (código \(exitCode)): \(output)"
            }
        }
    }

    /// Las apps abiertas desde Finder no heredan necesariamente el PATH del
    /// shell, por eso Homebrew y Nix se buscan también por ruta absoluta.
    private static let candidatePaths = [
        "/opt/homebrew/bin/acli",
        "/usr/local/bin/acli",
        "/usr/bin/acli",
        "/run/current-system/sw/bin/acli"
    ]

    static let executableURL: URL? = {
        let fileManager = FileManager.default
        let fromPath = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":")
            .map { "\($0)/acli" }
        for path in candidatePaths + fromPath where fileManager.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return nil
    }()

    static func authenticationStatus() async throws -> AuthenticationStatus {
        guard let executableURL else { throw Failure.notInstalled }
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let result = try runBlocking(executableURL, ["jira", "auth", "status"])
                    continuation.resume(returning: try classifyAuthentication(
                        exitCode: result.exitCode,
                        output: result.output
                    ))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Separado del proceso para fijar con tests el contrato observable de ACLI.
    static func classifyAuthentication(
        exitCode: Int32,
        output: String
    ) throws -> AuthenticationStatus {
        if exitCode == 0 { return .authenticated }
        if output.localizedCaseInsensitiveContains("unauthorized")
            || output.localizedCaseInsensitiveContains("auth login") {
            return .signedOut
        }
        throw Failure.commandFailed(
            exitCode: exitCode,
            output: output.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    private static func runBlocking(
        _ executableURL: URL,
        _ arguments: [String]
    ) throws -> (exitCode: Int32, output: String) {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice

        // Un solo archivo evita bloquear el proceso si cualquiera de las dos
        // salidas llena un pipe. Para este comando el orden no importa.
        let outputURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("work-buddy-\(UUID().uuidString).acli-output")
        FileManager.default.createFile(atPath: outputURL.path, contents: nil, attributes: nil)
        defer { try? FileManager.default.removeItem(at: outputURL) }

        let output = try FileHandle(forWritingTo: outputURL)
        process.standardOutput = output
        process.standardError = output

        try process.run()
        process.waitUntilExit()
        try output.close()

        let data = try Data(contentsOf: outputURL)
        return (
            process.terminationStatus,
            String(decoding: data, as: UTF8.self)
        )
    }
}
