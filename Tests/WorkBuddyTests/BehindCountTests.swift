import Foundation
import Testing

@testable import WorkBuddy

@Suite("Comparación contra la rama base")
struct BehindCountTests {
    @Test("Un alias por PR, todos en una request")
    func aliasPorPR() {
        let query = BehindCount.query(for: [
            makePullRequest(repository: "example-org/uno", base: "main", head: "rama-a"),
            makePullRequest(repository: "example-org/dos", base: "master", head: "rama-b")
        ])

        // Los alias son posicionales: el índice mapea de vuelta al PR.
        #expect(query.contains("p0: repository(owner: \"example-org\", name: \"uno\")"))
        #expect(query.contains("p1: repository(owner: \"example-org\", name: \"dos\")"))
        #expect(query.contains("ref(qualifiedName: \"main\")"))
        #expect(query.contains("ref(qualifiedName: \"master\")"))
        #expect(query.contains("compare(headRef: \"rama-a\")"))
        #expect(query.contains("behindBy"))
        // Una sola operación, no una por PR.
        #expect(query.hasPrefix("query {"))
    }

    @Test("El repo se parte en owner y name")
    func repoPartido() {
        let query = BehindCount.query(for: [
            makePullRequest(repository: "org/nombre-con-guiones", base: "main", head: "x")
        ])
        #expect(query.contains("owner: \"org\""))
        #expect(query.contains("name: \"nombre-con-guiones\""))
    }

    @Test("Las barras del nombre de rama no rompen nada")
    func ramaConBarras() {
        // Los nombres de dependabot son así: dependabot/npm_and_yarn/lodash-4.17.21
        let head = "dependabot/npm_and_yarn/fast-uri-3.1.7"
        let query = BehindCount.query(for: [
            makePullRequest(repository: "org/repo", base: "main", head: head)
        ])
        #expect(query.contains("compare(headRef: \"\(head)\")"))
        #expect(BehindCount.isSafeRef(head))
    }

    @Test("Refs con caracteres que romperían la query se consideran inseguros")
    func refsInseguros() {
        // Git no permite estos caracteres en un ref, así que interpolar es
        // seguro. La verificación existe para que, si eso cambiara, no midamos en
        // vez de emitir una query malformada.
        #expect(!BehindCount.isSafeRef("rama\"con-comilla"))
        #expect(!BehindCount.isSafeRef("rama\\con-barra"))
        #expect(!BehindCount.isSafeRef("rama con espacio"))
        #expect(!BehindCount.isSafeRef("rama\ncon-newline"))
        #expect(!BehindCount.isSafeRef(""))

        #expect(BehindCount.isSafeRef("main"))
        #expect(BehindCount.isSafeRef("release/1.2.3"))
    }

    @Test("Sin PRs no se arma una query vacía inválida")
    func sinPRs() async {
        let resultado = await BehindCount.fetch(for: [])
        #expect(resultado.isEmpty)
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
