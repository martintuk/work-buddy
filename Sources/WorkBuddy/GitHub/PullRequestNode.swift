import Foundation

/// PullRequest fields shared by queries.
enum PullRequestFields {
    /// viewerDefaultMergeMethod is a repository setting, not a computed verdict,
    /// so unlike mergeable it does not add mergeability calculation to the query.
    static let base = """
    id number title url isDraft updatedAt reviewDecision additions deletions
    baseRefName headRefName headRefOid
    repository { nameWithOwner viewerDefaultMergeMethod }
    author { login __typename }
    reviewRequests(first: 15) {
      nodes { requestedReviewer { ... on User { login } ... on Team { slug } } }
    }
    latestReviews(first: 10) { nodes { author { login } state } }
    myReview: reviews(author: $reviewAuthor, last: 1, states: [APPROVED, CHANGES_REQUESTED, DISMISSED]) {
      nodes { author { login } state }
    }
    commits(last: 1) { nodes { commit { statusCheckRollup { state } } } }
    """

    /// Dependabot requires confirmed absence of conflicts before offering review.
    /// That calculation is expensive, so its queue uses pages of 25.
    static let withMergeability = base + "\nmergeable"

    /// Merging also needs verdicts on required reviews and checks.
    /// Human review queues do not request these fields.
    static let withMergeState = withMergeability + " mergeStateStatus"
}

/// GraphQL PullRequest node. Fields are optional because inline search
/// fragments may return empty nodes for non-PR results, and some queries
/// do not request mergeable.
struct PullRequestNode: Decodable {
    let id: String?
    let number: Int?
    let title: String?
    let url: URL?
    let isDraft: Bool?
    let updatedAt: Date?
    let reviewDecision: String?
    let additions: Int?
    let deletions: Int?
    /// PR and base branches for comparison requests.
    let baseRefName: String?
    let headRefName: String?
    let headRefOid: String?
    let mergeable: String?
    let mergeStateStatus: String?
    let repository: Repository?
    let author: AuthorDTO?
    let reviewRequests: ReviewRequests?
    let latestReviews: Reviews?
    /// Latest personal decision; comments and drafts do not replace an approval.
    /// Query by author rather than relying on the first ten reviewers.
    let myReview: Reviews?
    let commits: Commits?

    struct Repository: Decodable {
        let nameWithOwner: String
        /// GitHub's default web merge method: SQUASH, MERGE, or REBASE.
        let viewerDefaultMergeMethod: String?
    }

    /// GitHub's __typename classifies Bot versus User;
    /// prefer that signal to guessing from the account name.
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
            /// Person requests have login; team requests have slug.
            /// That distinction is sufficient without __typename.
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
            approvals: reviews.count { $0.state == "APPROVED" },
            approvedByMe: myReview?.nodes.compactMap { $0 }.last.map {
                $0.author?.login.lowercased() == me.lowercased() && $0.state == "APPROVED"
            } ?? false,
            headRefOID: headRefOid,
            additions: additions,
            deletions: deletions
        )
    }
}

/// Shared GraphQL response envelope.
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

struct Viewer: Decodable, Sendable {
    let login: String

    /// Resolve the login used to filter personal reviews in PR queries.
    static func fetch() async throws -> Viewer {
        try await Diagnostics.measure(.viewer) {
            struct Payload: Decodable { let viewer: Viewer }
            let data = try await GH.runRetrying([
                "api", "graphql", "-f", "query=query { viewer { login } }"
            ])
            return try GraphQLResponse<Payload>.decode(data).viewer
        }
    }
}

extension GraphQLResponse {
    /// Decode GraphQL errors as thrown failures. A 200 response can contain
    /// an errors array; without this check, a server failure could look like an empty result.
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
    /// GitHub response decoder with ISO 8601 dates.
    static let github: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
