import Foundation
import Testing

@testable import WorkBuddy

struct LocalBranchCheckoutTests {
    private let switchArguments = ["switch", "--no-overwrite-ignore", "--", "feature/test"]
    private let fetchArguments = ["fetch", "--no-recurse-submodules", "--no-tags", "origin"]

    @Test("An existing verified branch opens without fetching")
    func localBranch() async throws {
        let folder = try await makeRepository()
        defer { try? FileManager.default.removeItem(at: folder) }
        _ = try await git(["branch", "feature/test"], folder)
        let commands = Commands()
        try await LocalBranchCheckout.run(request(folder), command: commands.run)
        #expect(await commands.mutations == [switchArguments])
        #expect(try await git(["branch", "--show-current"], folder) == "feature/test")
    }

    @Test("Non-conflicting edits follow the branch, including when already on it", arguments: [false, true])
    func preservedChanges(alreadyOnBranch: Bool) async throws {
        let folder = try await makeRepository()
        defer { try? FileManager.default.removeItem(at: folder) }
        _ = try await git(["branch", "feature/test"], folder)
        if alreadyOnBranch { _ = try await git(switchArguments, folder) }
        let file = folder.appendingPathComponent("tracked.txt")
        try Data("local work".utf8).write(to: file)
        let commands = Commands()
        try await LocalBranchCheckout.run(request(folder), command: commands.run)
        #expect(await commands.mutations == [switchArguments])
        #expect(try String(contentsOf: file, encoding: .utf8) == "local work")
        #expect(try await git(["branch", "--show-current"], folder) == "feature/test")
    }

    @Test("Conflicting edits fail immediately without fetch or losing work", arguments: [false, true])
    func conflictingChanges(staged: Bool) async throws {
        let folder = try await makeRepository()
        defer { try? FileManager.default.removeItem(at: folder) }
        _ = try await git(["switch", "-c", "feature/test"], folder)
        let file = folder.appendingPathComponent("tracked.txt")
        try Data("branch content".utf8).write(to: file)
        try await commit(folder)
        _ = try await git(["switch", "main"], folder)
        try Data("local work".utf8).write(to: file)
        if staged { _ = try await git(["add", "."], folder) }
        let commands = Commands()
        await #expect(throws: LocalBranchCheckout.Failure.self) {
            try await LocalBranchCheckout.run(request(folder), command: commands.run)
        }
        #expect(await commands.mutations == [switchArguments])
        #expect(try String(contentsOf: file, encoding: .utf8) == "local work")
        #expect(try await git(["branch", "--show-current"], folder) == "main")
    }

    @Test("Unknown branches fetch once; known remote branches need no fetch", arguments: [false, true])
    func remoteBranch(known: Bool) async throws {
        let source = try await makeRepository()
        defer { try? FileManager.default.removeItem(at: source) }
        let clone = source.appendingPathComponent("clone with spaces", isDirectory: true)
        if known { _ = try await git(["branch", "feature/test"], source) }
        _ = try await git(["clone", source.path, clone.path], source)
        if !known { _ = try await git(["branch", "feature/test"], source) }
        let commands = Commands(localRemote: true)
        try await LocalBranchCheckout.run(request(clone), command: commands.run)
        #expect(await commands.mutations == (known ? [trackingSwitch] : [fetchArguments, trackingSwitch]))
        #expect(try await git(["branch", "--show-current"], clone) == "feature/test")
        #expect(try await git(["rev-parse", "--abbrev-ref", "@{upstream}"], clone) == "origin/feature/test")
    }

    @Test("A branch still missing after fetch fails without looping")
    func missingAfterFetch() async throws {
        let source = try await makeRepository()
        defer { try? FileManager.default.removeItem(at: source) }
        let clone = source.appendingPathComponent("clone", isDirectory: true)
        _ = try await git(["clone", source.path, clone.path], source)
        let commands = Commands(localRemote: true)
        await #expect(throws: LocalBranchCheckout.VerificationError.self) {
            try await LocalBranchCheckout.run(request(clone), command: commands.run)
        }
        #expect(await commands.mutations == [fetchArguments])
        #expect(try await git(["branch", "--show-current"], clone) == "main")
    }

    @Test("A failed fetch propagates without retrying switch")
    func fetchFailure() async throws {
        let folder = try await makeRepository()
        defer { try? FileManager.default.removeItem(at: folder) }
        _ = try await git(["remote", "set-url", "origin", folder.appendingPathComponent("missing-remote").path], folder)
        let commands = Commands(localRemote: true)
        await #expect(throws: LocalBranchCheckout.Failure.self) {
            try await LocalBranchCheckout.run(request(folder), command: commands.run)
        }
        #expect(await commands.mutations == [fetchArguments])
    }

    @Test("An in-progress merge is reported without fetching")
    func mergeInProgress() async throws {
        let folder = try await makeRepository()
        defer { try? FileManager.default.removeItem(at: folder) }
        _ = try await git(["branch", "feature/test"], folder)
        let head = try await git(["rev-parse", "HEAD"], folder)
        try Data(head.utf8).write(to: folder.appendingPathComponent(".git/MERGE_HEAD"))
        let commands = Commands()
        await #expect(throws: LocalBranchCheckout.Failure.self) {
            try await LocalBranchCheckout.run(request(folder), command: commands.run)
        }
        #expect(await commands.mutations == [switchArguments])
        #expect(try await git(["branch", "--show-current"], folder) == "main")
    }

    @Test("A non-repository directory fails before Git is invoked")
    func invalidFolder() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let commands = Commands()
        let request = LocalBranchCheckout.Request(pullRequestID: "PR_42",
            url: URL(string: "https://github.com/org/repo/pull/42")!,
            repository: "org/repo", branch: "feature/test", folder: folder)
        await #expect(throws: EditorStore.EditorError.self) {
            try await LocalBranchCheckout.run(request, command: commands.run)
        }
        #expect(await commands.arguments.isEmpty)
    }

    @Test("Ignored files are not overwritten by branch switching")
    func ignoredFile() async throws {
        let folder = try await makeRepository()
        defer { try? FileManager.default.removeItem(at: folder) }
        _ = try await git(["switch", "-c", "feature/test"], folder)
        let file = folder.appendingPathComponent("local.txt")
        try Data("branch content".utf8).write(to: file)
        try await commit(folder)
        _ = try await git(["switch", "main"], folder)
        try Data("local.txt\n".utf8).write(to: folder.appendingPathComponent(".git/info/exclude"))
        try Data("local work".utf8).write(to: file)
        let commands = Commands()
        await #expect(throws: LocalBranchCheckout.Failure.self) {
            try await LocalBranchCheckout.run(request(folder), command: commands.run)
        }
        #expect(await commands.mutations == [switchArguments])
        #expect(try String(contentsOf: file, encoding: .utf8) == "local work")
    }

    @Test("A stale local branch is rejected without fetching or changing the checkout")
    func staleBranch() async throws {
        let folder = try await makeRepository()
        defer { try? FileManager.default.removeItem(at: folder) }
        _ = try await git(["branch", "feature/test"], folder)
        try Data("new revision".utf8).write(to: folder.appendingPathComponent("tracked.txt"))
        try await commit(folder)
        let expected = try await git(["rev-parse", "HEAD"], folder)
        let commands = Commands()
        await #expect(throws: LocalBranchCheckout.VerificationError.self) {
            try await LocalBranchCheckout.run(request(folder, expected: expected), command: commands.run)
        }
        #expect(await commands.mutations.isEmpty)
        #expect(try await git(["branch", "--show-current"], folder) == "main")
    }

    @Test("A same-name branch in a different repository is rejected")
    func wrongRepository() async throws {
        let folder = try await makeRepository()
        defer { try? FileManager.default.removeItem(at: folder) }
        _ = try await git(["branch", "feature/test"], folder)
        _ = try await git(["remote", "set-url", "origin", "git@github.com:other/repo.git"], folder)
        let commands = Commands()
        await #expect(throws: LocalBranchCheckout.VerificationError.self) {
            try await LocalBranchCheckout.run(request(folder), command: commands.run)
        }
        #expect(await commands.mutations.isEmpty)
    }

    @Test("An absent or malformed PR commit cannot launch an unchecked branch", arguments: ["", "HEAD", "1234567"])
    func missingCommit(value: String) async throws {
        let folder = try await makeRepository()
        defer { try? FileManager.default.removeItem(at: folder) }
        let request = LocalBranchCheckout.Request(pullRequestID: "PR_42",
            url: URL(string: "https://github.com/org/repo/pull/42")!, repository: "org/repo",
            branch: "feature/test", folder: folder, headRefOID: value.isEmpty ? nil : value)
        let commands = Commands()
        await #expect(throws: LocalBranchCheckout.VerificationError.self) {
            try await LocalBranchCheckout.run(request, command: commands.run)
        }
        #expect(await commands.arguments.isEmpty)
    }

    @Test("Only the verified remote supplies a missing local branch")
    func matchingRemote() async throws {
        let source = try await makeRepository()
        defer { try? FileManager.default.removeItem(at: source) }
        _ = try await git(["branch", "feature/test"], source)
        let clone = source.appendingPathComponent("clone", isDirectory: true)
        _ = try await git(["clone", source.path, clone.path], source)
        _ = try await git(["remote", "rename", "origin", "upstream"], clone)
        _ = try await git(["remote", "set-url", "upstream", "git@github.com:org/repo.git"], clone)
        _ = try await git(["remote", "add", "origin", "git@github.com:other/repo.git"], clone)
        let commands = Commands()
        try await LocalBranchCheckout.run(request(clone), command: commands.run)
        #expect(try await git(["rev-parse", "--abbrev-ref", "@{upstream}"], clone) == "upstream/feature/test")
        #expect(await commands.mutations.count == 1)
    }

    @Test("A remote branch with a different PR revision never becomes a local branch")
    func remoteRevisionMismatch() async throws {
        let source = try await makeRepository()
        defer { try? FileManager.default.removeItem(at: source) }
        _ = try await git(["branch", "feature/test"], source)
        try Data("different PR commit".utf8).write(to: source.appendingPathComponent("tracked.txt"))
        try await commit(source)
        let expected = try await git(["rev-parse", "HEAD"], source)
        let clone = source.appendingPathComponent("clone", isDirectory: true)
        _ = try await git(["clone", source.path, clone.path], source)
        let commands = Commands(localRemote: true)
        await #expect(throws: LocalBranchCheckout.VerificationError.self) {
            try await LocalBranchCheckout.run(request(clone, expected: expected), command: commands.run)
        }
        #expect(await commands.mutations == [fetchArguments])
        #expect(try await git(["branch", "--show-current"], clone) == "main")
        #expect(try await git(["branch", "--list", "feature/test"], clone) == "")
    }

    @Test("A commit changed by a checkout hook is rejected before launching")
    func revisionAfterSwitch() async throws {
        let folder = try await makeRepository()
        defer { try? FileManager.default.removeItem(at: folder) }
        _ = try await git(["branch", "feature/test"], folder)
        try Data("another commit".utf8).write(to: folder.appendingPathComponent("tracked.txt"))
        try await commit(folder)
        // Simulates a checkout hook changing HEAD after Git successfully switched branches.
        await #expect(throws: LocalBranchCheckout.VerificationError.self) {
            try await LocalBranchCheckout.run(request(folder)) { arguments, directory in
                let output = try await LocalBranchCheckout.git(arguments, in: directory)
                if arguments.first == "switch" {
                    _ = try await LocalBranchCheckout.git(["switch", "main"], in: directory)
                }
                return output
            }
        }
    }

    @Test("Remote identity accepts GitHub URL formats and requires the complete host and repository")
    func remoteIdentity() {
        for url in ["https://github.com/org/repo.git", "git@github.com:org/repo.git",
                    "ssh://git@github.com/org/repo", "https://GITHUB.COM/Org/Repo/"] {
            #expect(LocalBranchCheckout.remoteMatches(url, repository: "org/repo", host: "github.com"))
        }
        for url in ["https://github.com/other/repo", "https://github.com/org/repo-other",
                    "https://github.com.evil.test/org/repo", "https://elsewhere.test/org/repo",
                    "/tmp/org/repo", "file:///org/repo", "https://github.com/org/repo?x=1"] {
            #expect(!LocalBranchCheckout.remoteMatches(url, repository: "org/repo", host: "github.com"))
        }
        #expect(LocalBranchCheckout.remoteMatches("git@git.company.test:org/repo.git",
                                                  repository: "org/repo", host: "git.company.test"))
    }

    private var trackingSwitch: [String] {
        ["switch", "--no-overwrite-ignore", "-c", "feature/test", "--track", "--", "origin/feature/test"]
    }

    private func request(_ folder: URL, expected: String? = nil) async throws -> LocalBranchCheckout.Request {
        let oid: String
        if let expected { oid = expected }
        else if let branch = try? await git(["rev-parse", "--verify", "refs/heads/feature/test"], folder) { oid = branch }
        else { oid = try await git(["rev-parse", "HEAD"], folder) }
        return .init(pullRequestID: "PR_42", url: URL(string: "https://github.com/org/repo/pull/42")!,
              repository: "org/repo", branch: "feature/test", folder: folder, headRefOID: oid)
    }

    private func git(_ arguments: [String], _ folder: URL) async throws -> String {
        try await LocalBranchCheckout.git(arguments, in: folder)
    }

    private func commit(_ folder: URL) async throws {
        _ = try await git(["add", "."], folder)
        _ = try await git(["-c", "commit.gpgSign=false", "commit", "-m", "Fixture content"], folder)
    }

    private func makeRepository() async throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("work buddy tests \(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        _ = try await git(["init", "-b", "main"], folder)
        _ = try await git(["config", "user.name", "Work Buddy Tests"], folder)
        _ = try await git(["config", "user.email", "test@example.invalid"], folder)
        _ = try await git(["config", "core.hooksPath", "/dev/null"], folder)
        try Data("initial".utf8).write(to: folder.appendingPathComponent("tracked.txt"))
        try await commit(folder)
        _ = try await git(["remote", "add", "origin", "https://github.com/org/repo.git"], folder)
        return folder
    }
}

private actor Commands {
    private(set) var arguments: [[String]] = []
    let localRemote: Bool
    init(localRemote: Bool = false) { self.localRemote = localRemote }
    var mutations: [[String]] { arguments.filter { ["switch", "fetch"].contains($0.first ?? "") } }
    func run(_ arguments: [String], _ directory: URL) async throws -> String {
        self.arguments.append(arguments)
        // Fixtures fetch from disk; substitute only the remote identity to avoid network access.
        if localRemote && arguments == ["remote", "get-url", "origin"] {
            return "https://github.com/org/repo.git"
        }
        return try await LocalBranchCheckout.git(arguments, in: directory)
    }
}
