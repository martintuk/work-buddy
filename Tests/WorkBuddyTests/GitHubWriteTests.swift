import Foundation
import Testing

@testable import WorkBuddy

/// Los argumentos de las escrituras están fijados acá porque los tres detalles
/// que importan son invisibles leyendo el código: un flag que falta cuelga el
/// proceso, uno que sobra hace algo distinto de lo que dice la etiqueta.
@Suite("Escrituras contra GitHub")
struct GitHubWriteTests {
    @Test("Rebase actualiza la rama sin mergear ni comentar el PR")
    func rebaseNativo() {
        let arguments = GitHubWrite.rebase(repository: "org/repo", number: 42).arguments
        #expect(arguments == ["pr", "update-branch", "42", "--repo", "org/repo", "--rebase"])
    }

    @Test("Aprobar no manda comentario")
    func aprobarSinComentario() {
        // `--body` convertiría la aprobación en un comentario. Sin él es una
        // aprobación limpia, y sigue contando como review event para las reglas
        // de required reviewers.
        let arguments = GitHubWrite.approve(repository: "org/repo", number: 42).arguments
        #expect(arguments == ["pr", "review", "42", "--repo", "org/repo", "--approve"])
        #expect(!arguments.contains("--body"))
    }

    @Test("Mergear siempre lleva método explícito", arguments: MergeMethod.allCases)
    func mergearLlevaMetodo(method: MergeMethod) {
        // Sin flag de método, `gh pr merge` pregunta de forma interactiva y
        // cuelga el subproceso. Es el bug más fácil de introducir acá.
        let arguments = GitHubWrite.merge(
            repository: "org/repo",
            number: 7,
            method: method
        ).arguments

        #expect(arguments == ["pr", "merge", "7", "--repo", "org/repo", "--\(method.rawValue)"])

        // Alguno de los tres flags de método tiene que estar, siempre.
        let methodFlags = Set(MergeMethod.allCases.map { "--\($0.rawValue)" })
        #expect(!methodFlags.isDisjoint(with: arguments))
    }

    @Test("Mergear no usa --auto")
    func sinAutoMerge() {
        // El auto-merge está deshabilitado en estos repos, así que `--auto`
        // nunca armó nada. Peor: describía la acción como "activar auto-merge"
        // mientras a veces mergeaba en el acto.
        for method in MergeMethod.allCases {
            let arguments = GitHubWrite.merge(
                repository: "org/repo",
                number: 1,
                method: method
            ).arguments
            #expect(!arguments.contains("--auto"))
        }
    }

    @Test("El repo y el número salen como argumentos, no interpolados en texto")
    func sinInterpolacionEnUnSoloArgumento() {
        // Cada valor va en su propio elemento del argv, así un nombre de repo
        // raro no puede convertirse en flags extra.
        let arguments = GitHubWrite.merge(
            repository: "org/repo con espacios",
            number: 3,
            method: .squash
        ).arguments
        #expect(arguments.contains("org/repo con espacios"))
        #expect(arguments.count == 6)
    }
}

@Suite("Disponibilidad de acciones")
struct ActionAvailabilityTests {
    @Test("Rebase requiere atraso medido y excluye sólo a Dependabot")
    func disponibilidadDeRebase() {
        for author in [
            Author(login: "persona", typename: "User"),
            Author(login: "renovate", typename: "Bot"),
        ] {
            let pr = makePullRequest(author: author)
            #expect(pr.canRebase(behindBy: 1))
            #expect(!pr.canRebase(behindBy: 0))
            #expect(!pr.canRebase(behindBy: nil))
            #expect(!pr.canRebase(behindBy: -1))
        }
        for login in ["dependabot", "dependabot[bot]", "Dependabot"] {
            let pr = makePullRequest(author: Author(login: login, typename: "Bot"))
            #expect(!pr.canRebase(behindBy: 3))
        }
    }

    @Test("No se ofrece aprobar tus propios PRs")
    func noAprobarLoTuyo() {
        // GitHub lo rechaza, y un botón que sólo puede fallar entrena a ignorar
        // los errores.
        #expect(!makePullRequest(authoredByMe: true).canApprove)
        #expect(makePullRequest(authoredByMe: false).canApprove)
    }

    @Test("Sin datos de merge no se ofrece mergear")
    func noMergearSinDatos() {
        // La cola de review no pide `mergeable`, porque calcularlo es caro. Sin
        // ese dato no sabemos si se puede mergear, así que no lo ofrecemos.
        #expect(!makePullRequest().isReadyToMerge)
    }

    @Test("El método de merge lo dice GitHub, no lo elegimos")
    func metodoDesdeGraphQL() {
        #expect(MergeMethod(graphQL: "SQUASH") == .squash)
        #expect(MergeMethod(graphQL: "MERGE") == .merge)
        #expect(MergeMethod(graphQL: "REBASE") == .rebase)
        // Un valor nuevo del enum de GitHub no se adivina: sin método no se
        // ofrece mergear.
        #expect(MergeMethod(graphQL: "FAST_FORWARD") == nil)
        #expect(MergeMethod(graphQL: "squash") == nil)
    }

    @Test("Sin saber el método no se ofrece mergear")
    func sinMetodoNoSeOfrece() {
        let listo = makePullRequest(mergeable: .mergeable, mergeStateStatus: .clean)
        #expect(listo.canMerge)

        let sinMetodo = makePullRequest(
            mergeable: .mergeable,
            mergeStateStatus: .clean,
            defaultMergeMethod: nil
        )
        #expect(sinMetodo.isReadyToMerge)
        #expect(!sinMetodo.canMerge)
    }

    @Test("Sólo mergear pide confirmación")
    func confirmacionSoloParaMerge() {
        #expect(PullRequestAction.merge.needsConfirmation)
        #expect(!PullRequestAction.approve.needsConfirmation)
        #expect(!PullRequestAction.rebase.needsConfirmation)
        #expect(!PullRequestAction.ignore.needsConfirmation)
        #expect(!PullRequestAction.open.needsConfirmation)
    }

    @Test("Aprobar, mergear y rebasear escriben en GitHub")
    func cualesEscriben() {
        #expect(PullRequestAction.approve.writesToGitHub)
        #expect(PullRequestAction.merge.writesToGitHub)
        #expect(PullRequestAction.rebase.writesToGitHub)
        #expect(!PullRequestAction.open.writesToGitHub)
        #expect(!PullRequestAction.ignore.writesToGitHub)
        #expect(!PullRequestAction.restore.writesToGitHub)
    }
}

// MARK: - Helper

private func makePullRequest(
    author: Author? = nil,
    authoredByMe: Bool = false,
    mergeable: MergeableState? = nil,
    mergeStateStatus: MergeStateStatus? = nil,
    defaultMergeMethod: MergeMethod? = .squash
) -> PullRequest {
    PullRequest(
        id: "PR_\(UUID().uuidString)",
        number: 1,
        title: "un cambio",
        url: URL(string: "https://github.com/org/repo/pull/1")!,
        repository: "org/repo",
        baseRefName: "main",
        headRefName: "una-rama",
        author: author ?? Author(login: authoredByMe ? "yo" : "otro", typename: "User"),
        updatedAt: .now,
        isDraft: false,
        checks: .success,
        reviewDecision: .reviewRequired,
        mergeable: mergeable,
        mergeStateStatus: mergeStateStatus,
        defaultMergeMethod: defaultMergeMethod,
        authoredByMe: authoredByMe,
        requestedFromMe: true,
        reviewedByMe: false,
        approvals: 0, approvedByMe: false
    )
}
