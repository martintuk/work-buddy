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

    @Test("La cola de dependabot no pide mergeable")
    func dependabotSinMergeable() {
        // `mergeable` obliga a GitHub a calcular la mergeabilidad. Con los 50 PRs
        // de dependabot en una página devuelve **502** de forma consistente
        // (verificado 3/3); con 25 anda. Un dependabot listo para mergear llega
        // por `MergeQueue`, que trae un puñado.
        let query = PullRequestSearch.query(
            search: DependabotQueue.baseSearchQuery,
            fields: PullRequestFields.base,
            pageSize: 50
        )
        #expect(!query.contains("mergeable"))
        #expect(!query.contains("mergeStateStatus"))
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
        #expect(query.contains("query($cursor: String)"))
        #expect(query.contains("after: $cursor"))
        #expect(query.contains("hasNextPage"))
        #expect(query.contains("endCursor"))
        #expect(query.contains("first: 25"))
    }

    @Test("La cola de merge sí pide el estado de merge")
    func mergeQueuePideMergeable() {
        // El complemento del test de arriba: es la única query que lo pide, y sin
        // eso la sección "Listos para mergear" no puede existir.
        #expect(PullRequestFields.withMergeState.contains("mergeable"))
        #expect(PullRequestFields.withMergeState.contains("mergeStateStatus"))
        #expect(!PullRequestFields.base.contains("mergeable"))
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
