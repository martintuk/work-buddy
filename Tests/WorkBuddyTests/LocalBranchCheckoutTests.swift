import Foundation
import Testing

@testable import WorkBuddy

struct LocalBranchCheckoutTests {
    @Test("Checks out the exact PR in the configured folder, with no force or worktree flags")
    func checkoutInPlace() async throws {
        let folder = try await makeRepository()
        defer { try? FileManager.default.removeItem(at: folder) }
        _ = try await LocalBranchCheckout.git(["branch", "feature/test"], in: folder)
        let request = request(folder)
        try await LocalBranchCheckout.run(request) { arguments, directory in
            #expect(arguments == ["pr", "checkout", "https://github.com/org/repo/pull/42"])
            #expect(directory == folder)
            _ = try await LocalBranchCheckout.git(["switch", "feature/test"], in: directory)
        }
        #expect(try await LocalBranchCheckout.git(["branch", "--show-current"], in: folder) == "feature/test")
    }

    @Test("Local changes are preserved and checkout is never called", arguments: ["untracked", "tracked", "staged"])
    func dirtyRepository(kind: String) async throws {
        let folder = try await makeRepository()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent(kind == "untracked" ? "new file.txt" : "tracked.txt")
        try Data("local work".utf8).write(to: file)
        if kind == "staged" { _ = try await LocalBranchCheckout.git(["add", "."], in: folder) }
        do {
            try await LocalBranchCheckout.run(request(folder)) { _, _ in Issue.record("Checkout must not run") }
            Issue.record("Expected local changes error")
        } catch LocalBranchCheckout.Failure.localChanges { }
        #expect(try String(contentsOf: file, encoding: .utf8) == "local work")
        #expect(try await LocalBranchCheckout.git(["branch", "--show-current"], in: folder) == "main")
    }

    @Test("In-progress Git operations block checkout even with a clean index", arguments: [
        "MERGE_HEAD", "CHERRY_PICK_HEAD", "REVERT_HEAD", "rebase-merge", "rebase-apply", "sequencer", "BISECT_START"
    ])
    func inProgress(marker: String) async throws {
        let folder = try await makeRepository()
        defer { try? FileManager.default.removeItem(at: folder) }
        let head = try await LocalBranchCheckout.git(["rev-parse", "HEAD"], in: folder)
        try Data(head.utf8).write(to: folder.appendingPathComponent(".git/\(marker)"))
        do {
            try await LocalBranchCheckout.run(request(folder)) { _, _ in Issue.record("Checkout must not run") }
            Issue.record("Expected in-progress error")
        } catch LocalBranchCheckout.Failure.operationInProgress { }
    }

    @Test("Incorrect associations cannot fetch PRs into an unrelated repository")
    func wrongRepository() async throws {
        let folder = try await makeRepository()
        defer { try? FileManager.default.removeItem(at: folder) }
        _ = try await LocalBranchCheckout.git(["remote", "set-url", "origin", "git@github.com:other/repo.git"], in: folder)
        do {
            try await LocalBranchCheckout.run(request(folder)) { _, _ in Issue.record("Checkout must not run") }
            Issue.record("Expected wrong repository error")
        } catch LocalBranchCheckout.Failure.wrongRepository { }
    }

    @Test("Common SSH and HTTPS remotes match without accepting other hosts or repos")
    func remoteIdentity() {
        let request = request(URL(fileURLWithPath: "/tmp/repo"))
        for remote in ["git@github.com:org/repo.git", "https://github.com/org/repo", "ssh://git@github.com/ORG/REPO.git"] {
            #expect(LocalBranchCheckout.matchesRepository(remote, request: request))
        }
        for remote in ["https://evil.example/org/repo", "git@github.com:other/repo.git", "/tmp/org/repo", "https://github.com/org/repo-extra"] {
            #expect(!LocalBranchCheckout.matchesRepository(remote, request: request))
        }
    }

    @Test("Git failures propagate without resetting or cleaning the project")
    func checkoutFailure() async throws {
        let folder = try await makeRepository()
        defer { try? FileManager.default.removeItem(at: folder) }
        do {
            try await LocalBranchCheckout.run(request(folder)) { _, _ in
                throw LocalBranchCheckout.Failure.git("Branch unavailable")
            }
            Issue.record("Expected checkout error")
        } catch LocalBranchCheckout.Failure.git(let detail) {
            #expect(detail == "Branch unavailable")
        }
        #expect(try await LocalBranchCheckout.git(["branch", "--show-current"], in: folder) == "main")
    }

    private func request(_ folder: URL) -> LocalBranchCheckout.Request {
        .init(pullRequestID: "PR_42", url: URL(string: "https://github.com/org/repo/pull/42")!,
              repository: "org/repo", branch: "feature/test", folder: folder)
    }

    private func makeRepository() async throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("work buddy tests \(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        _ = try await LocalBranchCheckout.git(["init", "-b", "main"], in: folder)
        _ = try await LocalBranchCheckout.git(["config", "user.name", "Work Buddy Tests"], in: folder)
        _ = try await LocalBranchCheckout.git(["config", "user.email", "test@example.invalid"], in: folder)
        _ = try await LocalBranchCheckout.git(["config", "core.hooksPath", "/dev/null"], in: folder)
        try Data("initial".utf8).write(to: folder.appendingPathComponent("tracked.txt"))
        _ = try await LocalBranchCheckout.git(["add", "."], in: folder)
        _ = try await LocalBranchCheckout.git(["-c", "commit.gpgSign=false", "commit", "-m", "Initial fixture"], in: folder)
        _ = try await LocalBranchCheckout.git(["remote", "add", "origin", "git@github.com:org/repo.git"], in: folder)
        return folder
    }
}
