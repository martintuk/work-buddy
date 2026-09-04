import Foundation

/// Invoca el CLI `gh`.
///
/// Usamos el CLI en vez de hablarle a la API de GitHub directamente para
/// reusar la sesión que ya tenés en el keyring: la app nunca ve un token.
enum GH {
    enum Failure: LocalizedError {
        case notInstalled
        case notAuthenticated(String)
        case commandFailed(exitCode: Int32, stderr: String)
        case badJSON(String)
        case missingThreads(String)
        case missingComments(String)
        case missingConversationCursor
        case noAttempts

        var errorDescription: String? {
            switch self {
            case .notInstalled:
                L10n.text(.errorGHMissing)
            case .notAuthenticated(let detail):
                L10n.text(.errorGHAuthentication, detail)
            case .commandFailed(let code, let stderr):
                L10n.text(.errorGHCommand, String(code), stderr)
            case .badJSON(let detail):
                L10n.text(.errorGHResponse, detail)
            case .missingThreads(let id):
                L10n.text(.errorGHResponse, L10n.text(.errorMissingThreads, id))
            case .missingComments(let id):
                L10n.text(.errorGHResponse, L10n.text(.errorMissingComments, id))
            case .missingConversationCursor:
                L10n.text(.errorGHResponse, L10n.text(.errorConversationCursor))
            case .noAttempts:
                L10n.text(.errorGHCommand, "-1", L10n.text(.errorNoAttempts))
            }
        }
    }

    /// Rutas donde buscar `gh`, en orden.
    ///
    /// No alcanza con confiar en PATH: una app lanzada desde Finder **no** hereda
    /// el PATH del shell, así que `gh` a secas no resuelve. Buscamos a mano.
    private static let candidatePaths = [
        "/opt/homebrew/bin/gh", // Homebrew en Apple Silicon
        "/usr/local/bin/gh", // Homebrew en Intel
        "/usr/bin/gh",
        "/run/current-system/sw/bin/gh" // Nix
    ]

    /// Ruta al ejecutable, resuelta una sola vez.
    static let executableURL: URL? = {
        let fileManager = FileManager.default
        let fromPath = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":")
            .map { "\($0)/gh" }
        for path in candidatePaths + fromPath where fileManager.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return nil
    }()

    /// Verifica que `gh` exista y tenga sesión activa. Llamar antes de consultar.
    static func preflight() async throws {
        guard executableURL != nil else { throw Failure.notInstalled }
        do {
            _ = try await run(["auth", "status"])
        } catch let Failure.commandFailed(_, stderr) {
            throw Failure.notAuthenticated(stderr)
        }
    }

    /// Igual que `run`, pero reintenta ante fallas transitorias.
    ///
    /// GitHub devuelve **502** de forma intermitente en queries GraphQL con
    /// conexiones anidadas: medido contra la API real, falla más o menos 1 de
    /// cada 4 intentos. Sin reintentar, el panel mostraría un error al azar.
    static func runRetrying(_ arguments: [String], attempts: Int = 4) async throws -> Data {
        var lastError: Error = Failure.noAttempts
        for attempt in 0 ..< attempts {
            do {
                return try await run(arguments)
            } catch let failure as Failure {
                guard case .commandFailed(_, let stderr) = failure, isTransient(stderr) else {
                    throw failure
                }
                lastError = failure
                // Backoff exponencial: 300ms, 600ms, 1.2s…
                try? await Task.sleep(for: .milliseconds(300 << attempt))
            }
        }
        throw lastError
    }

    private static func isTransient(_ stderr: String) -> Bool {
        ["HTTP 502", "HTTP 503", "HTTP 504", "timeout", "connection reset"]
            .contains { stderr.localizedCaseInsensitiveContains($0) }
    }

    /// Corre `gh` con estos argumentos y devuelve stdout.
    ///
    /// Los argumentos van directo al proceso, sin pasar por un shell: no hay que
    /// escapar nada ni hay riesgo de inyección al interpolar valores.
    static func run(_ arguments: [String]) async throws -> Data {
        guard let executableURL else { throw Failure.notInstalled }
        return try await withCheckedThrowingContinuation { continuation in
            // Process y Pipe no son Sendable, así que viven enteros dentro de
            // runBlocking, fuera del contexto de concurrencia.
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    continuation.resume(returning: try runBlocking(executableURL, arguments))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func runBlocking(_ executableURL: URL, _ arguments: [String]) throws -> Data {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments

        let output = Pipe()
        process.standardOutput = output

        // Sin stdin: si un comando de `gh` decide preguntar algo —`gh pr merge`
        // sin flag de método lo hace— recibe EOF y falla, en vez de colgar el
        // proceso esperando input que nunca va a llegar.
        process.standardInput = FileHandle.nullDevice

        // stderr va a un archivo temporal, no a un pipe: si los dos fueran pipes
        // y llenáramos el buffer de stderr mientras drenamos stdout, `gh` se
        // colgaría esperando que alguien lea.
        let errorURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("work-buddy-\(UUID().uuidString).stderr")
        FileManager.default.createFile(atPath: errorURL.path, contents: nil, attributes: nil)
        defer { try? FileManager.default.removeItem(at: errorURL) }
        process.standardError = try FileHandle(forWritingTo: errorURL)

        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let stderr = (try? String(contentsOf: errorURL, encoding: .utf8)) ?? ""
            throw Failure.commandFailed(
                exitCode: process.terminationStatus,
                stderr: stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        return data
    }
}
