import Foundation

/// Invoke gh to reuse its existing keychain session
/// instead of handling a GitHub API token in the app.
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

    /// Executable search paths, in order. Finder-launched apps may not inherit
    /// the shell's PATH, so do not rely on bare gh resolution.
    private static let candidatePaths = [
        "/opt/homebrew/bin/gh", // Homebrew en Apple Silicon
        "/usr/local/bin/gh", // Homebrew en Intel
        "/usr/bin/gh",
        "/run/current-system/sw/bin/gh" // Nix
    ]

    /// Resolve the executable path once.
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

    /// Verify gh exists and is authenticated before querying.
    static func preflight() async throws {
        guard executableURL != nil else { throw Failure.notInstalled }
        do {
            _ = try await run(["auth", "status"])
        } catch let Failure.commandFailed(_, stderr) {
            throw Failure.notAuthenticated(stderr)
        }
    }

    /// Like run, with retries for transient failures. Nested GraphQL connections
    /// produced intermittent 502 responses in roughly one of four measured attempts;
    /// retrying avoids random panel failures from those responses.
    static func runRetrying(_ arguments: [String], attempts: Int = 4) async throws -> Data {
        var lastError: Error = Failure.noAttempts
        for attempt in 0 ..< attempts {
            if attempt > 0 { Diagnostics.record(.retry, metrics: [.attempt: attempt + 1], error: lastError) }
            do {
                return try await run(arguments)
            } catch {
                let transient: Bool
                if case Failure.commandFailed(_, let stderr) = error {
                    transient = isTransient(stderr)
                } else if let failure = error as? GitHubAPIError {
                    transient = [502, 503, 504].contains(failure.response.status)
                } else {
                    transient = false
                }
                guard transient else { throw error }
                lastError = error
                // Exponential backoff: 300 ms, 600 ms, 1.2 s, ...
                try? await Task.sleep(for: .milliseconds(300 << attempt))
            }
        }
        throw lastError
    }

    /// API calls only: response headers distinguish rate limits from permission failures.
    /// Writes never use generic retries for uncertain errors.
    static func runAPI(_ arguments: [String], retryingRead: Bool = false) async throws -> Data {
        let included = arguments + ["--include"]
        let data = try await (retryingRead ? runRetrying(included) : run(included))
        return try GitHubAPIResponse(data).body
    }

    private static func isTransient(_ stderr: String) -> Bool {
        ["HTTP 502", "HTTP 503", "HTTP 504", "timeout", "connection reset"]
            .contains { stderr.localizedCaseInsensitiveContains($0) }
    }

    /// Run gh with separate process arguments and return stdout.
    /// No shell is involved, so interpolated values require no shell escaping.
    static func run(_ arguments: [String], in directory: URL? = nil) async throws -> Data {
        try await Diagnostics.measure(.gh) {
            guard let executableURL else { throw Failure.notInstalled }
            let result = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
                // Process and Pipe are not Sendable; keep them inside runBlocking,
                // outside the concurrency context.
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        continuation.resume(returning: try runBlocking(executableURL, arguments, directory: directory))
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
            Diagnostics.record(.counts, metrics: [.bytes: result.count])
            return result
        }
    }

    private static func runBlocking(_ executableURL: URL, _ arguments: [String], directory: URL?) throws -> Data {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.currentDirectoryURL = directory
        if directory != nil {
            var environment = ProcessInfo.processInfo.environment
            environment["GH_PROMPT_DISABLED"] = "1"
            environment["GIT_TERMINAL_PROMPT"] = "0"
            process.environment = environment
        }

        let output = Pipe()
        process.standardOutput = output

        // Use no stdin. Interactive commands, such as gh pr merge without a method,
        // receive EOF and fail instead of hanging for input that will never arrive.
        process.standardInput = FileHandle.nullDevice

        // Write stderr to a temporary file. Two pipes could deadlock if stderr
        // filled while the caller drained stdout.
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
            if arguments.first == "api", arguments.contains("--include"),
               let response = try? GitHubAPIResponse(data), response.status >= 400 {
                throw GitHubAPIError(response: response, detail: stderr.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            throw Failure.commandFailed(
                exitCode: process.terminationStatus,
                stderr: stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        return data
    }
}
