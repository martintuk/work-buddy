import Foundation
import Testing

@testable import WorkBuddy

@Suite("Base branch comparison")
struct BehindCountTests {
    @Test("One alias per PR, all in one request")
    func aliasPerPR() {
        let query = BehindCount.query(for: [
            makePullRequest(repository: "example-org/one", base: "main", head: "branch-a"),
            makePullRequest(repository: "example-org/dos", base: "master", head: "branch-b")
        ])

        // Aliases are positional: each index maps back to its PR.
        #expect(query.contains("p0: repository(owner: \"example-org\", name: \"one\")"))
        #expect(query.contains("p1: repository(owner: \"example-org\", name: \"dos\")"))
        #expect(query.contains("ref(qualifiedName: \"main\")"))
        #expect(query.contains("ref(qualifiedName: \"master\")"))
        #expect(query.contains("compare(headRef: \"branch-a\")"))
        #expect(query.contains("behindBy"))
        // One operation, not one per PR.
        #expect(query.hasPrefix("query {"))
    }

    @Test("Split repositories into owner and name")
    func repositoryComponents() {
        let query = BehindCount.query(for: [
            makePullRequest(repository: "org/nombre-con-guiones", base: "main", head: "x")
        ])
        #expect(query.contains("owner: \"org\""))
        #expect(query.contains("name: \"nombre-con-guiones\""))
    }

    @Test("Branch names containing slashes remain valid")
    func branchWithSlashes() {
        // Dependabot branch names follow this pattern: dependabot/npm_and_yarn/lodash-4.17.21
        let head = "dependabot/npm_and_yarn/fast-uri-3.1.7"
        let query = BehindCount.query(for: [
            makePullRequest(repository: "org/repo", base: "main", head: head)
        ])
        #expect(query.contains("compare(headRef: \"\(head)\")"))
        #expect(BehindCount.isSafeRef(head))
    }

    @Test("Reject refs containing characters that could break the query")
    func unsafeRefs() {
        // Git forbids these characters in refs, making interpolation safe. If that changes, validation skips measurement instead of emitting a malformed query.
        #expect(!BehindCount.isSafeRef("rama\"con-comilla"))
        #expect(!BehindCount.isSafeRef("rama\\con-barra"))
        #expect(!BehindCount.isSafeRef("rama con espacio"))
        #expect(!BehindCount.isSafeRef("rama\ncon-newline"))
        #expect(!BehindCount.isSafeRef(""))

        #expect(BehindCount.isSafeRef("main"))
        #expect(BehindCount.isSafeRef("release/1.2.3"))
    }

    @Test("No PRs means no invalid empty query")
    func noPRs() async {
        let result = await BehindCount.fetch(for: [])
        #expect(result.isEmpty)
    }
}

// MARK: - Helper

private func makePullRequest(
    repository: String,
    base: String,
    head: String
) -> PullRequest {
    PullRequest(
        id: "PR_\(UUID().uuidString)",
        number: 1,
        title: "un cambio",
        url: URL(string: "https://github.com/\(repository)/pull/1")!,
        repository: repository,
        baseRefName: base,
        headRefName: head,
        author: Author(login: "dependabot", typename: "Bot"),
        updatedAt: .now,
        isDraft: false,
        checks: .success,
        reviewDecision: .reviewRequired,
        mergeable: nil,
        mergeStateStatus: nil,
        defaultMergeMethod: .squash,
        authoredByMe: false,
        requestedFromMe: true,
        reviewedByMe: false,
        approvals: 0, approvedByMe: false
    )
}
