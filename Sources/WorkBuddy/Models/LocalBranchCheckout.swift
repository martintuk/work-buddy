import Foundation

/// Cambia el checkout existente, nunca crea worktrees ni descarta trabajo local.
enum LocalBranchCheckout {
    struct Request: Sendable {
        let pullRequestID: String
        let url: URL
        let repository: String
        let branch: String
        let folder: URL

        init(pullRequest: PullRequest, folder: URL) {
            pullRequestID = pullRequest.id
            url = pullRequest.url
            repository = pullRequest.repository
            branch = pullRequest.headRefName
            self.folder = folder
        }

        init(pullRequestID: String, url: URL, repository: String, branch: String, folder: URL) {
            self.pullRequestID = pullRequestID
            self.url = url
            self.repository = repository
            self.branch = branch
            self.folder = folder
        }
    }

    struct Failure: LocalizedError {
        let exitCode: Int32
        let stderr: String
        var errorDescription: String? { stderr }

        func isUnknownBranch(_ branch: String) -> Bool {
            // LC_ALL=C hace estable el diagnóstico. Otros fallos no disparan fetch.
            exitCode == 128 && stderr == "fatal: invalid reference: \(branch)"
        }
    }

    static func run(
        _ request: Request,
        command: @Sendable ([String], URL) async throws -> String = { arguments, folder in
            try await git(arguments, in: folder)
        }
    ) async throws {
        // Fast path: un proceso, sin status, inspección de remotos ni red.
        // No se fuerza el cambio, ni siquiera para archivos ignorados.
        let arguments = ["switch", "--no-overwrite-ignore", "--", request.branch]
        do {
            _ = try await command(arguments, request.folder)
        } catch let failure as Failure where failure.isUnknownBranch(request.branch) {
            // Usa el remoto configurado por Git, sin gh ni listas de remotos.
            _ = try await command(["fetch", "--no-recurse-submodules"], request.folder)
            _ = try await command(arguments, request.folder)
        }
    }

    /// Proceso fuera del main actor, con argumentos separados y sin prompts.
    static func git(_ arguments: [String], in folder: URL) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = ["-C", folder.path] + arguments
            var environment = ProcessInfo.processInfo.environment
            environment["LC_ALL"] = "C"
            environment["GIT_TERMINAL_PROMPT"] = "0"
            process.environment = environment
            process.standardInput = FileHandle.nullDevice
            let output = Pipe()
            process.standardOutput = output
            let errorURL = FileManager.default.temporaryDirectory.appendingPathComponent("work-buddy-git-\(UUID().uuidString)")
            FileManager.default.createFile(atPath: errorURL.path, contents: nil)
            defer { try? FileManager.default.removeItem(at: errorURL) }
            let errors = try FileHandle(forWritingTo: errorURL)
            defer { try? errors.close() }
            process.standardError = errors
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                let stderr = (try? String(contentsOf: errorURL, encoding: .utf8)) ?? "Git failed"
                throw Failure(exitCode: process.terminationStatus,
                              stderr: stderr.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        }.value
    }
}
