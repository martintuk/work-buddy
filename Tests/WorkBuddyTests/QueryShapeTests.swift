import Foundation
import Testing

@testable import WorkBuddy

/// Los filtros de búsqueda no fallan cuando están mal: devuelven **menos**. Un
/// typo en un qualifier no tira error, hace que la app omita PRs en silencio.
/// Por eso están fijados acá.
@Suite("Forma de las queries de búsqueda")
struct QueryShapeTests {
    @Test("Las dos colas de review son complementarias exactas")
    func complementarias() {
        // Si las dos excluyeran dependabot, desaparecerían 50 PRs. Si las dos lo
        // incluyeran, cada uno aparecería dos veces y el store no deduplica la
        // cola de review, justamente porque confía en esto.
        #expect(ReviewQueue.baseSearchQuery.contains("-author:app/dependabot"))
        #expect(DependabotQueue.baseSearchQuery.contains("author:app/dependabot"))
        #expect(!DependabotQueue.baseSearchQuery.contains("-author:app/dependabot"))

        // Fuera del filtro de autor, tienen que pedir lo mismo.
        let sinFiltro: (String) -> String = { query in
            query
                .replacingOccurrences(of: "-author:app/dependabot", with: "")
                .replacingOccurrences(of: "author:app/dependabot", with: "")
                .trimmingCharacters(in: .whitespaces)
        }
        #expect(sinFiltro(ReviewQueue.baseSearchQuery)
            == sinFiltro(DependabotQueue.baseSearchQuery))
    }

    @Test(
        "Las colas usan el review-requested que incluye pedidos vía equipo",
        arguments: [ReviewQueue.baseSearchQuery, DependabotQueue.baseSearchQuery]
    )
    func incluyePedidosDeEquipo(query: String) {
        // Medido: `review-requested:@me` trae 57 PRs y `user-review-requested:@me`
        // sólo 27, porque el segundo excluye los que te llegan por pertenecer a un
        // equipo. Usar el segundo perdería más de la mitad de la cola —y es
        // justamente lo que hace que no necesitemos una lista de repos a mano.
        #expect(query.contains("review-requested:@me"))
        #expect(!query.contains("user-review-requested:@me"))
        #expect(query.contains("is:open"))
        #expect(query.contains("is:pr"))
        // Sin esto entran PRs de repos archivados, que no se pueden mergear.
        #expect(query.contains("archived:false"))
    }

    @Test("Dependabot consulta conflictos con páginas de 25 y conserva las ocho páginas")
    func dependabotPideMergeable() async throws {
        let prs = try await DependabotQueue.fetch(viewer: Viewer(login: "me")) { arguments in
            let query = try #require(arguments.first { $0.hasPrefix("query=") })
            #expect(query.contains(DependabotQueue.baseSearchQuery))
            #expect(query.contains("mergeable"))
            #expect(!query.contains("mergeStateStatus"))
            #expect(query.contains("first: 25"))
            #expect(arguments.contains("reviewAuthor=me"))
            let page = arguments.first { $0.hasPrefix("cursor=") }
                .flatMap { Int($0.dropFirst("cursor=".count)) } ?? 0
            return try JSONSerialization.data(withJSONObject: ["data": [
                "viewer": ["login": "me"],
                "search": [
                    "pageInfo": ["hasNextPage": page < 7, "endCursor": String(page + 1)],
                    "nodes": [[
                        "id": "PR_\(page)", "number": page + 1, "title": "Dependency update",
                        "url": "https://github.com/org/repo/pull/\(page + 1)",
                        "repository": ["nameWithOwner": "org/repo"],
                        "author": ["login": "dependabot", "__typename": "Bot"],
                        "baseRefName": "main", "headRefName": "dependabot/update-\(page)",
                        "updatedAt": "2026-09-30T00:00:00Z", "mergeable": "MERGEABLE",
                        "commits": ["nodes": [["commit": ["statusCheckRollup": ["state": "SUCCESS"]]]]]
                    ]]
                ]
            ]])
        }
        #expect(prs.count == 8)
        #expect(prs.awaitingYourReview.count == 8)
    }

    @Test("La query paginada declara cursor y lo pide de vuelta")
    func paginacion() {
        let query = PullRequestSearch.query(
            search: "is:open is:pr",
            fields: "id",
            pageSize: 25
        )
        // Sin `hasNextPage`/`endCursor` la paginación se corta en la primera
        // página sin avisar.
        #expect(query.contains("query($cursor: String, $reviewAuthor: String!)"))
        #expect(query.contains("after: $cursor"))
        #expect(query.contains("hasNextPage"))
        #expect(query.contains("endCursor"))
        #expect(query.contains("first: 25"))
    }

    @Test("La cola de merge sí pide el estado de merge")
    func mergeQueuePideMergeable() {
        // Merge también necesita el veredicto sobre las condiciones requeridas.
        #expect(PullRequestFields.withMergeState.contains("mergeable"))
        #expect(PullRequestFields.withMergeState.contains("mergeStateStatus"))
        #expect(!PullRequestFields.base.contains("mergeable"))
    }

    @Test("La decisión personal no depende de una página de reviews ajenas")
    func reviewPersonalPorAutor() {
        #expect(PullRequestFields.base.contains(
            "myReview: reviews(author: $reviewAuthor, last: 1, states: [APPROVED, CHANGES_REQUESTED, DISMISSED])"
        ))
        #expect(MergeQueue.query(configuration: .empty).contains("query($reviewAuthor: String!)"))
    }

    @Test("Para Fixear busca autoría propia sin exigir review ni CI exitosa")
    func fixQueueScope() throws {
        #expect(FixQueue.baseSearchQuery == "is:open is:pr author:@me archived:false")
        let configuration = try AppConfiguration(organizations: ["example-org"], machineAccountsText: "")
        #expect(FixQueue.searchQuery(configuration: configuration).hasSuffix("org:example-org"))
        #expect(FixQueue.searchQuery(configuration: .empty) == FixQueue.baseSearchQuery)
    }

    @Test("La organización configurada limita todas las búsquedas")
    func alcancePorOrganizacion() throws {
        let configuration = try AppConfiguration(
            organizations: ["example-org"],
            machineAccountsText: ""
        )

        #expect(ReviewQueue.searchQuery(configuration: configuration)
            .hasSuffix("org:example-org"))
        #expect(DependabotQueue.searchQuery(configuration: configuration)
            .hasSuffix("org:example-org"))

        let mergeQuery = MergeQueue.query(configuration: configuration)
        #expect(mergeQuery.components(separatedBy: "org:example-org").count - 1 == 3)
    }

    @Test("Sin organización configurada el alcance sigue siendo global")
    func alcanceGlobalPorDefecto() {
        #expect(ReviewQueue.searchQuery(configuration: .empty)
            == ReviewQueue.baseSearchQuery)
        #expect(DependabotQueue.searchQuery(configuration: .empty)
            == DependabotQueue.baseSearchQuery)
        #expect(!MergeQueue.query(configuration: .empty).contains("org:"))
    }
}
