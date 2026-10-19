import Foundation

/// Invoke Atlassian's official CLI without shell assumptions.
/// Authentication happens in Terminal; the app only checks status and never receives credentials.
enum ACLI {
    enum AuthenticationStatus: Equatable, Sendable {
        case authenticated(site: URL?)
        case signedOut
    }

    enum Failure: LocalizedError {
        case notInstalled
        case notAuthenticated
        case commandFailed(exitCode: Int32, output: String)
        case badJSON(String)

        var errorDescription: String? {
            switch self {
            case .notInstalled:
                L10n.text(.errorACLIMissing)
            case .notAuthenticated:
                L10n.text(.errorACLIAuthentication)
            case .commandFailed(let exitCode, let output):
                L10n.text(.errorACLICommand, String(exitCode), output)
            case .badJSON(let detail):
                L10n.text(.errorACLIResponse, detail)
            }
        }
    }

    /// Finder apps may not inherit shell PATH; also check absolute Homebrew and Nix paths.
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
        let result = try await execute(["jira", "auth", "status"])
        return try classifyAuthentication(
            exitCode: result.exitCode,
            output: result.combinedOutput
        )
    }

    /// Separate process execution from ACLI's observable authentication contract for tests.
    static func classifyAuthentication(
        exitCode: Int32,
        output: String
    ) throws -> AuthenticationStatus {
        if exitCode == 0 { return .authenticated(site: siteURL(in: output)) }
        if output.localizedCaseInsensitiveContains("unauthorized")
            || output.localizedCaseInsensitiveContains("auth login") {
            return .signedOut
        }
        throw Failure.commandFailed(
            exitCode: exitCode,
            output: output.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    static func run(_ arguments: [String]) async throws -> Data {
        let result = try await execute(arguments)
        guard result.exitCode == 0 else {
            if outputMeansSignedOut(result.combinedOutput) {
                throw Failure.notAuthenticated
            }
            throw Failure.commandFailed(
                exitCode: result.exitCode,
                output: result.combinedOutput.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        return result.stdout
    }

    private static func execute(_ arguments: [String]) async throws -> CommandResult {
        try await Diagnostics.measure(.acli) {
            guard let executableURL else { throw Failure.notInstalled }
            let result = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<CommandResult, Error>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        continuation.resume(returning: try runBlocking(executableURL, arguments))
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
            Diagnostics.record(.counts, metrics: [.bytes: result.stdout.count])
            if result.exitCode != 0 {
                Diagnostics.record(.failed, error: Failure.commandFailed(exitCode: result.exitCode, output: result.combinedOutput))
            }
            return result
        }
    }

    private static func outputMeansSignedOut(_ output: String) -> Bool {
        output.localizedCaseInsensitiveContains("unauthorized")
            || output.localizedCaseInsensitiveContains("auth login")
    }

    private static func siteURL(in output: String) -> URL? {
        guard let line = output.split(whereSeparator: \Character.isNewline).first(where: {
            $0.trimmingCharacters(in: .whitespaces).hasPrefix("Site:")
        }) else { return nil }

        let value = line
            .trimmingCharacters(in: .whitespaces)
            .dropFirst("Site:".count)
            .trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty else { return nil }
        return URL(string: value.hasPrefix("http") ? value : "https://\(value)")
    }

    private struct CommandResult: Sendable {
        let exitCode: Int32
        let stdout: Data
        let stderr: String

        var combinedOutput: String {
            [String(decoding: stdout, as: UTF8.self), stderr]
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
        }
    }

    private static func runBlocking(
        _ executableURL: URL,
        _ arguments: [String]
    ) throws -> CommandResult {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice

        let stdout = Pipe()
        process.standardOutput = stdout

        // Use a stderr file so draining stdout cannot block on another full pipe.
        let stderrURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("work-buddy-\(UUID().uuidString).acli-stderr")
        FileManager.default.createFile(atPath: stderrURL.path, contents: nil, attributes: nil)
        defer { try? FileManager.default.removeItem(at: stderrURL) }
        let stderr = try FileHandle(forWritingTo: stderrURL)
        process.standardError = stderr

        try process.run()
        let stdoutData = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        try stderr.close()

        return CommandResult(
            exitCode: process.terminationStatus,
            stdout: stdoutData,
            stderr: String(decoding: try Data(contentsOf: stderrURL), as: UTF8.self)
        )
    }
}
