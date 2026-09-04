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

    enum Failure: LocalizedError {
        case localChanges, operationInProgress, wrongRepository
        case git(String)

        var errorDescription: String? {
            switch self {
            case .localChanges: L10n.text(.editorBranchLocalChanges)
            case .operationInProgress: L10n.text(.editorBranchOperationInProgress)
            case .wrongRepository: L10n.text(.editorBranchWrongRepository)
            case .git(let detail): detail
            }
        }
    }

    static func run(
        _ request: Request,
        checkout: @Sendable ([String], URL) async throws -> Void = { arguments, folder in
            _ = try await GH.run(arguments, in: folder)
        }
    ) async throws {
        let folder = request.folder
        guard FileManager.default.fileExists(atPath: folder.appendingPathComponent(".git").path) else {
            throw EditorStore.EditorError.missingFolder
        }
        // Incluye archivos nuevos, staged y cambios en submódulos. No hacemos stash.
        guard try await git(["status", "--porcelain=v1", "--untracked-files=all", "--ignore-submodules=none"], in: folder).isEmpty else {
            throw Failure.localChanges
        }
        for marker in ["MERGE_HEAD", "CHERRY_PICK_HEAD", "REVERT_HEAD", "rebase-merge", "rebase-apply", "sequencer", "BISECT_START"] {
            let path = try await git(["rev-parse", "--git-path", marker], in: folder)
            if FileManager.default.fileExists(atPath: URL(fileURLWithPath: path, relativeTo: folder).path) {
                throw Failure.operationInProgress
            }
        }
        // Una asociación manual no garantiza que la carpeta sea del repo del PR.
        let remotes = try await git(["remote"], in: folder).split(separator: "\n")
        var matches = false
        for remote in remotes {
            let address = try await git(["remote", "get-url", "--", String(remote)], in: folder)
            if matchesRepository(address, request: request) { matches = true }
        }
        guard matches else { throw Failure.wrongRepository }
        // La URL identifica el PR incluso si viene de un fork; sólo el nombre
        // de la rama podría elegir otra rama homónima. Sin --force ni --detach.
        try await checkout(["pr", "checkout", request.url.absoluteString], folder)
    }

    static func matchesRepository(_ address: String, request: Request) -> Bool {
        let normalized: String
        if !address.contains("://"), let colon = address.firstIndex(of: ":") {
            normalized = "ssh://" + address[..<colon] + "/" + address[address.index(after: colon)...]
        } else {
            normalized = address
        }
        guard let remote = URLComponents(string: normalized),
              let host = remote.host, host.lowercased() == request.url.host?.lowercased() else { return false }
        var path = remote.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if path.hasSuffix(".git") { path.removeLast(4) }
        return path.lowercased() == request.repository.lowercased()
    }

    /// Proceso fuera del main actor, con argumentos separados y sin prompts.
    static func git(_ arguments: [String], in folder: URL) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = ["-C", folder.path] + arguments
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
                throw Failure.git((try? String(contentsOf: errorURL, encoding: .utf8)) ?? "Git failed")
            }
            return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        }.value
    }
}
