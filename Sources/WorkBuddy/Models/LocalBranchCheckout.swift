import Foundation

/// Switch the existing checkout without creating worktrees or discarding local work.
enum LocalBranchCheckout {
    struct Request: Sendable {
        let pullRequestID: String
        let url: URL
        let repository: String
        let branch: String
        let headRefOID: String?
        let folder: URL

        init(pullRequest: PullRequest, folder: URL) {
            pullRequestID = pullRequest.id
            url = pullRequest.url
            repository = pullRequest.repository
            branch = pullRequest.headRefName
            headRefOID = pullRequest.headRefOID
            self.folder = folder
        }

        init(pullRequestID: String, url: URL, repository: String, branch: String, folder: URL, headRefOID: String? = nil) {
            self.pullRequestID = pullRequestID
            self.url = url
            self.repository = repository
            self.branch = branch
            self.headRefOID = headRefOID
            self.folder = folder
        }
    }

    struct Failure: LocalizedError {
        let exitCode: Int32
        let stderr: String
        var errorDescription: String? { stderr }
    }

    enum VerificationError: LocalizedError {
        case wrongRepository, missingCommit, wrongRevision(String)

        var errorDescription: String? {
            switch self {
            case .wrongRepository: L10n.text(.editorBranchWrongRepository)
            case .missingCommit: L10n.text(.editorBranchMissingCommit)
            case .wrongRevision(let branch): L10n.text(.editorBranchWrongRevision, branch)
            }
        }
    }

    static func run(
        _ request: Request,
        command: @Sendable ([String], URL) async throws -> String = { arguments, folder in
            try await git(arguments, in: folder)
        }
    ) async throws {
        guard FileManager.default.fileExists(atPath: request.folder.appendingPathComponent(".git").path) else {
            throw EditorStore.EditorError.missingFolder
        }
        guard let expected = request.headRefOID?.lowercased(),
              expected.range(of: #"^(?:[a-f0-9]{40}|[a-f0-9]{64})$"#, options: .regularExpression) != nil else {
            throw VerificationError.missingCommit
        }
        _ = try await command(["check-ref-format", "refs/heads/\(request.branch)"], request.folder)
        let remotes = try await command(["remote"], request.folder).split(whereSeparator: \.isNewline).map(String.init)
        var matchingRemote: String?
        for remote in remotes.sorted(by: { $0 == "origin" ? $1 != "origin" : ($1 != "origin" && $0 < $1) }) {
            let url = try await command(["remote", "get-url", remote], request.folder)
            if remoteMatches(url, repository: request.repository, host: request.url.host) {
                matchingRemote = remote
                break
            }
        }
        guard let remote = matchingRemote else { throw VerificationError.wrongRepository }

        func revision(_ ref: String) async throws -> String? {
            do {
                return try await command(["rev-parse", "--verify", "--quiet", "--end-of-options", "\(ref)^{commit}"], request.folder)
                    .lowercased()
            } catch let error as Failure where error.exitCode == 1 {
                return nil // Referencia ausente; otros errores no habilitan fetch ni checkout.
            }
        }

        if let local = try await revision("refs/heads/\(request.branch)") {
            guard local == expected else { throw VerificationError.wrongRevision(request.branch) }
            _ = try await command(["switch", "--no-overwrite-ignore", "--", request.branch], request.folder)
        } else {
            let trackingRef = "refs/remotes/\(remote)/\(request.branch)"
            if try await revision(trackingRef) != expected {
                _ = try await command(["fetch", "--no-recurse-submodules", "--no-tags", remote], request.folder)
            }
            guard try await revision(trackingRef) == expected else {
                throw VerificationError.wrongRevision(request.branch)
            }
            // Explicitly choose the verified remote to avoid guessing among same-named branches.
            _ = try await command(["switch", "--no-overwrite-ignore", "-c", request.branch,
                                   "--track", "--", "\(remote)/\(request.branch)"], request.folder)
        }
        guard try await revision("HEAD") == expected else { throw VerificationError.wrongRevision(request.branch) }
    }

    /// HTTPS/SSH URLs and SCP syntax; require complete owner/repository and host matches.
    static func remoteMatches(_ remote: String, repository: String, host: String?) -> Bool {
        guard let host else { return false }
        let remoteHost: String
        var path: String
        if remote.contains("://"), let url = URLComponents(string: remote),
           ["https", "http", "ssh", "git"].contains(url.scheme?.lowercased() ?? ""),
           let parsedHost = url.host, url.query == nil, url.fragment == nil {
            remoteHost = parsedHost
            path = url.path
        } else {
            let parts = remote.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2, !parts[0].contains("/") else { return false }
            remoteHost = String(parts[0].split(separator: "@").last ?? "")
            path = String(parts[1])
        }
        path = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if path.hasSuffix(".git") { path.removeLast(4) }
        return remoteHost.lowercased() == host.lowercased() && path.lowercased() == repository.lowercased()
    }

    /// Run off the main actor with separate arguments and no prompts.
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
