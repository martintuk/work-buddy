import Foundation

/// Campos de PullRequest que piden las queries.
enum PullRequestFields {
    /// `viewerDefaultMergeMethod` es un setting del repo y no algo que GitHub
    /// tenga que calcular, así que pedirlo en la query grande no la encarece —
    /// a diferencia de `mergeable`, que sí.
    static let base = """
    id number title url isDraft updatedAt reviewDecision
    baseRefName headRefName
    repository { nameWithOwner viewerDefaultMergeMethod }
    author { login __typename }
    reviewRequests(first: 15) {
      nodes { requestedReviewer { ... on User { login } ... on Team { slug } } }
    }
    latestReviews(first: 10) { nodes { author { login } state } }
    commits(last: 1) { nodes { commit { statusCheckRollup { state } } } }
    """

    /// `mergeable` obliga a GitHub a calcular la mergeabilidad, que es caro. Lo
    /// pedimos sólo en la query de "listos para mergear", que devuelve un puñado
    /// de PRs, y no en la cola de review, que trae decenas.
    static let withMergeState = base + "\nmergeable mergeStateStatus"
}

/// Nodo de PullRequest tal como viene de GraphQL.
///
/// Todos los campos son opcionales porque `search` con un fragmento inline puede
/// devolver nodos vacíos para resultados que no son PullRequest, y porque
/// `mergeable` sólo se pide en algunas queries.
struct PullRequestNode: Decodable {
    let id: String?
    let number: Int?
    let title: String?
    let url: URL?
    let isDraft: Bool?
    let updatedAt: Date?
    let reviewDecision: String?
    /// Ramas base y del PR, para poder compararlas contra la compare API.
    let baseRefName: String?
    let headRefName: String?
    let mergeable: String?
    let mergeStateStatus: String?
    let repository: Repository?
    let author: AuthorDTO?
    let reviewRequests: ReviewRequests?
    let latestReviews: Reviews?
    let commits: Commits?

    struct Repository: Decodable {
        let nameWithOwner: String
        /// El método que GitHub te daría en la web: `SQUASH`, `MERGE` o `REBASE`.
        let viewerDefaultMergeMethod: String?
    }

    /// `__typename` es la clasificación de GitHub: `Bot` para dependabot y
    /// compañía, `User` para gente. Es más confiable que adivinar por el nombre.
    struct AuthorDTO: Decodable {
        let login: String
        let typename: String?

        enum CodingKeys: String, CodingKey {
            case login
            case typename = "__typename"
        }
    }

    struct ReviewRequests: Decodable {
        let nodes: [Item?]
        struct Item: Decodable {
            let requestedReviewer: Reviewer?
            /// `login` viene poblado si el pedido es a una persona, `slug` si es
            /// a un equipo. Nos alcanza para distinguirlos, sin `__typename`.
            struct Reviewer: Decodable {
                let login: String?
                let slug: String?
            }
        }
    }

    struct Reviews: Decodable {
        let nodes: [Item?]
        struct Item: Decodable {
            let author: Reviewer?
            let state: String?
            struct Reviewer: Decodable { let login: String }
        }
    }

    struct Commits: Decodable {
        let nodes: [Item?]
        struct Item: Decodable {
            let commit: Commit?
            struct Commit: Decodable {
                let statusCheckRollup: Rollup?
                struct Rollup: Decodable { let state: String? }
            }
        }
    }

    func toPullRequest(me: String, machineAccounts: Set<String> = []) -> PullRequest? {
        guard let id, let number, let title, let url,
              let repository, let updatedAt,
              let baseRefName, let headRefName else { return nil }

        let reviewers = (reviewRequests?.nodes ?? []).compactMap { $0?.requestedReviewer }
        let reviews = (latestReviews?.nodes ?? []).compactMap { $0 }
        let rollup = commits?.nodes.compactMap { $0 }.first?.commit?.statusCheckRollup?.state
        let login = author?.login ?? "desconocido"

        return PullRequest(
            id: id,
            number: number,
            title: title,
            url: url,
            repository: repository.nameWithOwner,
            baseRefName: baseRefName,
            headRefName: headRefName,
            author: Author(
                login: login,
                typename: author?.typename,
                machineAccounts: machineAccounts
            ),
            updatedAt: updatedAt,
            isDraft: isDraft ?? false,
            checks: rollup.flatMap(CheckState.init(rawValue:)) ?? .unknown,
            reviewDecision: reviewDecision.flatMap(ReviewDecision.init(rawValue:)),
            mergeable: mergeable.flatMap(MergeableState.init(rawValue:)),
            mergeStateStatus: mergeStateStatus.flatMap(MergeStateStatus.init(rawValue:)),
            defaultMergeMethod: repository.viewerDefaultMergeMethod
                .flatMap(MergeMethod.init(graphQL:)),
            authoredByMe: login == me,
            requestedFromMe: reviewers.contains { $0.login == me },
            reviewedByMe: reviews.contains { $0.author?.login == me },
            approvals: reviews.count { $0.state == "APPROVED" }
        )
    }
}

/// Envoltorio común de las respuestas de GraphQL.
struct GraphQLResponse<Payload: Decodable>: Decodable {
    let data: Payload
    let errors: [GraphQLError]?

    struct GraphQLError: Decodable { let message: String }
}

struct SearchPage: Decodable {
    let pageInfo: PageInfo?
    let nodes: [PullRequestNode?]

    struct PageInfo: Decodable {
        let hasNextPage: Bool
        let endCursor: String?
    }
}

struct Viewer: Decodable { let login: String }

extension GraphQLResponse {
    /// Decodifica y convierte los errores de GraphQL en un throw.
    ///
    /// GraphQL responde 200 con un array `errors` cuando algo falla, así que sin
    /// esto un error del servidor pasaría por respuesta vacía.
    static func decode(_ data: Data) throws -> Payload {
        do {
            let response = try JSONDecoder.github.decode(Self.self, from: data)
            if let message = response.errors?.first?.message {
                throw GH.Failure.badJSON("GraphQL: \(message)")
            }
            return response.data
        } catch let failure as GH.Failure {
            throw failure
        } catch {
            throw GH.Failure.badJSON(String(describing: error))
        }
    }
}

extension JSONDecoder {
    /// Decoder para respuestas de GitHub, con fechas ISO 8601.
    static let github: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
