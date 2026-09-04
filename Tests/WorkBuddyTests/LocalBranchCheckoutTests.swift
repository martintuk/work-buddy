import Foundation
import Testing

@testable import WorkBuddy

struct LocalBranchCheckoutTests {
    private let switchArguments = ["switch", "--no-overwrite-ignore", "--", "feature/test"]
    private let fetchArguments = ["fetch", "--no-recurse-submodules"]

    @Test("An existing branch opens with one local command and no remote")
    func localBranch() async throws {
        let folder = try await makeRepository()
        defer { try? FileManager.default.removeItem(at: folder) }
        _ = try await git(["branch", "feature/test"], folder)
        let commands = Commands()
        try await LocalBranchCheckout.run(request(folder), command: commands.run)
        #expect(await commands.arguments == [switchArguments])
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
        #expect(await commands.arguments == [switchArguments])
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
        #expect(await commands.arguments == [switchArguments])
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
        let commands = Commands()
        try await LocalBranchCheckout.run(request(clone), command: commands.run)
        #expect(await commands.arguments == (known ? [switchArguments] : [switchArguments, fetchArguments, switchArguments]))
        #expect(try await git(["branch", "--show-current"], clone) == "feature/test")
        #expect(try await git(["rev-parse", "--abbrev-ref", "@{upstream}"], clone) == "origin/feature/test")
    }

    @Test("A branch still missing after fetch fails without looping")
    func missingAfterFetch() async throws {
        let source = try await makeRepository()
        defer { try? FileManager.default.removeItem(at: source) }
        let clone = source.appendingPathComponent("clone", isDirectory: true)
        _ = try await git(["clone", source.path, clone.path], source)
        let commands = Commands()
        await #expect(throws: LocalBranchCheckout.Failure.self) {
            try await LocalBranchCheckout.run(request(clone), command: commands.run)
        }
        #expect(await commands.arguments == [switchArguments, fetchArguments, switchArguments])
        #expect(try await git(["branch", "--show-current"], clone) == "main")
    }

    @Test("A failed fetch propagates without retrying switch")
    func fetchFailure() async throws {
        let folder = try await makeRepository()
        defer { try? FileManager.default.removeItem(at: folder) }
        _ = try await git(["remote", "add", "origin", folder.appendingPathComponent("missing-remote").path], folder)
        let commands = Commands()
        await #expect(throws: LocalBranchCheckout.Failure.self) {
            try await LocalBranchCheckout.run(request(folder), command: commands.run)
        }
        #expect(await commands.arguments == [switchArguments, fetchArguments])
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
        #expect(await commands.arguments == [switchArguments])
        #expect(try await git(["branch", "--show-current"], folder) == "main")
    }

    @Test("A non-repository directory fails without extra checks or fetch")
    func invalidFolder() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let commands = Commands()
        await #expect(throws: LocalBranchCheckout.Failure.self) {
            try await LocalBranchCheckout.run(request(folder), command: commands.run)
        }
        #expect(await commands.arguments == [switchArguments])
    }

    @Test("A branch name matching a file cannot restore that file")
    func fileNotBranch() async throws {
        let folder = try await makeRepository()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("tracked.txt")
        try Data("local work".utf8).write(to: file)
        await #expect(throws: LocalBranchCheckout.Failure.self) {
            try await LocalBranchCheckout.run(request(folder, branch: "tracked.txt"))
        }
        #expect(try String(contentsOf: file, encoding: .utf8) == "local work")
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
        #expect(await commands.arguments == [switchArguments])
        #expect(try String(contentsOf: file, encoding: .utf8) == "local work")
    }

    @Test("Only the missing-branch diagnostic triggers fetch")
    func errorClassification() {
        #expect(LocalBranchCheckout.Failure(exitCode: 128, stderr: "fatal: invalid reference: feature/test").isUnknownBranch("feature/test"))
        for message in ["fatal: invalid reference: other", "fatal: cannot switch branch while merging", "fatal: 'feature/test' matched multiple remote tracking branches", "fatal: Unable to create index.lock", "fatal: not a git repository"] {
            #expect(!LocalBranchCheckout.Failure(exitCode: 128, stderr: message).isUnknownBranch("feature/test"))
        }
    }

    private func request(_ folder: URL, branch: String = "feature/test") -> LocalBranchCheckout.Request {
        .init(pullRequestID: "PR_42", url: URL(string: "https://github.com/org/repo/pull/42")!,
              repository: "org/repo", branch: branch, folder: folder)
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
        return folder
    }
}

private actor Commands {
    private(set) var arguments: [[String]] = []
    func run(_ arguments: [String], _ directory: URL) async throws -> String {
        self.arguments.append(arguments)
        return try await LocalBranchCheckout.git(arguments, in: directory)
    }
}
