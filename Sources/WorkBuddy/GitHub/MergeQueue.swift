import Foundation

/// Trae los PRs que ya se podrían mergear.
///
/// Son tres búsquedas, pero van en una sola request usando alias de GraphQL.
enum MergeQueue {
    /// Tres búsquedas, porque ninguna sola cubre lo que podés mergear:
    ///
    /// - `author:@me` — los tuyos.
    /// - `reviewed-by:@me` — los que revisaste. **Es la que más aporta.**
    ///   Aprobar un PR te saca de sus review requests, así que el acto que lo
    ///   vuelve mergeable es el mismo que lo sacaría de la búsqueda de abajo.
    ///   Sin ésta, un PR de automatización que aprobaste desaparecía: medido,
    ///   la sección pasó de 1 a 5 PRs al agregarla.
    /// - `review-requested:@me review:approved` — los aprobados por otros donde
    ///   todavía figurás como reviewer. Es el caso raro, pero existe.
    ///
    /// Sólo la última lleva `review:approved`, y ahí es imprescindible: recorta
    /// de 56 PRs a 2. Medido, no pierde nada, porque en esta org todos los repos
    /// exigen review y un PR mergeable siempre tiene `APPROVED` (45 de 56
    /// estaban `BLOCKED`). Ver `docs/supuestos.md`.
    ///
    /// A `reviewed-by:@me` **no** se lo ponemos: da 12 sin el filtro y 7 con, y a
    /// esa escala no compra nada y agrega un supuesto que puede podrirse.
    static func query(configuration: AppConfiguration) -> String {
        let authored = configuration.scopedSearch("is:open is:pr author:@me archived:false")
        let reviewed = configuration.scopedSearch("is:open is:pr reviewed-by:@me archived:false")
        let reviewing = configuration.scopedSearch(
            "is:open is:pr review-requested:@me review:approved archived:false"
        )
        return """
    query($reviewAuthor: String!) {
      viewer { login }
      authored: search(
        query: "\(authored)"
        type: ISSUE
        first: 30
      ) {
        nodes { ... on PullRequest { \(PullRequestFields.withMergeState) } }
      }
      reviewed: search(
        query: "\(reviewed)"
        type: ISSUE
        first: 30
      ) {
        nodes { ... on PullRequest { \(PullRequestFields.withMergeState) } }
      }
      reviewing: search(
        query: "\(reviewing)"
        type: ISSUE
        first: 30
      ) {
        nodes { ... on PullRequest { \(PullRequestFields.withMergeState) } }
      }
    }
    """
    }

    struct Payload: Decodable {
        let viewer: Viewer
        let authored: SearchPage
        let reviewed: SearchPage
        let reviewing: SearchPage
    }

    /// Devuelve los candidatos ya deduplicados. Filtrar por "listo para mergear"
    /// es responsabilidad de `[PullRequest].readyToMerge`.
    static func fetch(configuration: AppConfiguration = .empty, viewer: Viewer) async throws -> [PullRequest] {
        let query = query(configuration: configuration)
        let data = try await GH.runRetrying([
            "api", "graphql", "-f", "query=\(query)", "-f", "reviewAuthor=\(viewer.login)"
        ])
        let payload = try GraphQLResponse<Payload>.decode(data)
        let me = payload.viewer.login

        let candidates = (payload.authored.nodes + payload.reviewed.nodes + payload.reviewing.nodes)
            .compactMap {
                $0?.toPullRequest(me: me, machineAccounts: configuration.machineAccounts)
            }

        // Las búsquedas se solapan: un PR que revisaste y en el que todavía
        // figurás como reviewer aparece en dos de las tres.
        var seen: Set<String> = []
        return candidates.filter { seen.insert($0.id).inserted }
    }
}
