import Foundation

/// Identificadores completos org/slug; nunca presupone equipos de una empresa.
enum GitHubTeams {
    private struct Team: Decodable {
        struct Organization: Decodable { let login: String }
        let slug: String
        let organization: Organization
    }

    static func fetch() async throws -> [String] {
        try await GH.preflight()
        return try decode(await GH.runRetrying([
            "api", "user/teams?per_page=100", "--paginate", "--slurp"
        ]))
    }

    static func decode(_ data: Data) throws -> [String] {
        let pages = try JSONDecoder().decode([[Team]].self, from: data)
        return Set(pages.flatMap { $0.map { "\($0.organization.login)/\($0.slug)".lowercased() } }).sorted()
    }
}

enum TeamDependabot {
    struct QueueResult: Sendable {
        let pullRequests: [PullRequest]?
        let error: String?
    }

    static func load(configuration: AppConfiguration, viewer: Viewer, force: Bool = false) async -> QueueResult {
        guard !configuration.effectiveDependabotTeams.isEmpty else {
            Diagnostics.record(.disabled)
            return QueueResult(pullRequests: [], error: nil)
        }
        do {
            // Permite marcar varias casillas sin arrancar un recorrido por cada click.
            try await Task.sleep(for: .milliseconds(500))
            let discovery = try await Diagnostics.measure(.ownership) {
                try await TeamDependabotCache.shared.resolve(
                    teams: configuration.effectiveDependabotTeams, login: viewer.login, force: force
                )
            }
            if discovery.error != nil { Diagnostics.record(.partial) }
            if discovery.error != nil && discovery.repositories.isEmpty {
                return QueueResult(pullRequests: nil, error: discovery.error)
            }
            let prs = try await fetch(repositories: discovery.repositories, configuration: configuration, viewer: viewer)
            return QueueResult(pullRequests: prs, error: discovery.error)
        } catch {
            Diagnostics.record(.failed, error: error)
            return QueueResult(pullRequests: nil, error: error.localizedDescription)
        }
    }

    typealias Request = @Sendable ([String]) async throws -> Data

    struct Repository: Decodable, Sendable {
        let full_name: String
        let default_branch: String?
        let archived: Bool
    }

    private struct Contents: Decodable {
        struct File: Decodable { let text: String? }
        struct Repository: Decodable {
            let primary: File?
            let root: File?
            let docs: File?
        }
        let repository: Repository?
    }

    /// La última regla global reemplaza las anteriores. Las reglas por ruta no
    /// amplían el alcance: esto detecta responsabilidad general, no evalúa diffs.
    static func hasGeneralOwnership(_ source: String, identities: Set<String>) -> Bool {
        let identities = Set(identities.map { $0.lowercased() })
        var owners: Set<String> = []
        for line in source.split(whereSeparator: \.isNewline) {
            let code = line.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0]
            let fields = code.split(whereSeparator: \.isWhitespace)
            guard fields.first == "*" else { continue }
            owners = Set(fields.dropFirst().map { $0.lowercased() })
        }
        return !owners.isDisjoint(with: identities)
    }

    static func discover(
        teams: [String], login: String,
        request: Request = { try await GH.runRetrying($0) }
    ) async throws -> [String] {
        var repositories: [String: Repository] = [:]
        for team in teams {
            try Task.checkCancellation()
            let parts = team.split(separator: "/")
            let data = try await request([
                "api", "orgs/\(parts[0])/teams/\(parts[1])/repos?per_page=100", "--paginate", "--slurp"
            ])
            let pages = try JSONDecoder().decode([[Repository]].self, from: data)
            for repo in pages.flatMap({ $0 }) where !repo.archived {
                repositories[repo.full_name.lowercased()] = repo
            }
        }
        let identities = Set(teams.map { "@\($0)" } + ["@\(login)"])
        Diagnostics.record(.counts, metrics: [.teams: teams.count, .repositories: repositories.count])
        var owned: [String] = []
        // Una lectura por repo resuelve las tres ubicaciones sin confundir un
        // 404 de permisos con un archivo ausente. Las respuestas parciales fallan.
        let query = """
        query($owner: String!, $name: String!, $primary: String!, $root: String!, $docs: String!) {
          repository(owner: $owner, name: $name) {
            primary: object(expression: $primary) { ... on Blob { text } }
            root: object(expression: $root) { ... on Blob { text } }
            docs: object(expression: $docs) { ... on Blob { text } }
          }
        }
        """
        for (name, repo) in repositories.sorted(by: { $0.key < $1.key }) {
            try Task.checkCancellation()
            guard let branch = repo.default_branch else { continue } // Repo vacío.
            let parts = name.split(separator: "/")
            guard parts.count == 2,
                  name.range(of: #"^[a-z0-9-]+/[a-z0-9_.-]+$"#, options: .regularExpression) != nil else {
                throw GH.Failure.badJSON(name)
            }
            let data = try await request([
                "api", "graphql", "-f", "query=\(query)",
                "-f", "owner=\(parts[0])", "-f", "name=\(parts[1])",
                "-f", "primary=\(branch):.github/CODEOWNERS",
                "-f", "root=\(branch):CODEOWNERS", "-f", "docs=\(branch):docs/CODEOWNERS"
            ])
            let payload = try GraphQLResponse<Contents>.decode(data)
            guard let contents = payload.repository else { throw GH.Failure.badJSON(name) }
            guard let file = contents.primary ?? contents.root ?? contents.docs else { continue }
            guard let text = file.text else { throw GH.Failure.badJSON("\(name): CODEOWNERS") }
            if hasGeneralOwnership(text, identities: identities) { owned.append(name) }
        }
        return owned
    }

    /// Queries pequeñas para no exceder el límite de longitud de búsqueda. No
    /// llevan org: además de repo:, para evitar ensanchar el alcance por accidente.
    static func searches(repositories: [String]) -> [String] {
        let base = "is:open is:pr archived:false author:app/dependabot"
        var searches: [String] = []
        var current = base
        for repo in Set(repositories).sorted() {
            let qualifier = " repo:\(repo)"
            if current.count + qualifier.count > 240, current != base {
                searches.append(current)
                current = base
            }
            current += qualifier
        }
        if current != base { searches.append(current) }
        return searches
    }

    /// Preferencia de diagnóstico, leída en cada carga para poder comparar máquinas.
    static func searchConcurrency(defaults: UserDefaults = .standard) -> Int {
        let value = defaults.object(forKey: "performance.teamSearchConcurrency") as? Int ?? 2
        return max(1, min(8, value))
    }

    static func fetch(
        repositories: [String], configuration: AppConfiguration, viewer: Viewer,
        concurrency: Int = searchConcurrency(),
        request: @escaping Request = { try await GH.runRetrying($0) }
    ) async throws -> [PullRequest] {
        let queries = searches(repositories: repositories)
        let limit = max(1, min(8, concurrency))
        Diagnostics.record(.counts, metrics: [.concurrency: limit, .searches: queries.count])

        @Sendable func fetchSearch(_ index: Int) async throws -> (Int, [PullRequest]) {
            try Task.checkCancellation()
            let prs = try await Diagnostics.measure(.teamSearch) {
                try await PullRequestSearch.fetch(
                    viewer: viewer,
                    search: queries[index], fields: PullRequestFields.withMergeState,
                    pageSize: 25, maxPages: 40, machineAccounts: configuration.machineAccounts,
                    request: request
                )
            }
            return (index, prs)
        }

        return try await withThrowingTaskGroup(of: (Int, [PullRequest]).self) { group in
            var results = Array(repeating: [PullRequest](), count: queries.count)
            var next = min(limit, queries.count)
            for index in 0..<next {
                group.addTask { try await fetchSearch(index) }
            }
            while let (index, prs) = try await group.next() {
                try Task.checkCancellation()
                results[index] = prs
                if next < queries.count {
                    let index = next
                    group.addTask { try await fetchSearch(index) }
                    next += 1
                }
            }
            // Conserva el orden y la precedencia al deduplicar, aunque las
            // respuestas lleguen en otro orden. Un fallo descarta el conjunto.
            return results.flatMap { $0 }.uniquedByID()
        }
    }
}

/// Caché persistente por cuenta y selección efectiva. Nunca publica un recorrido
/// parcial ni reutiliza repos de equipos que el usuario acaba de desmarcar.
actor TeamDependabotCache {
    static let shared = TeamDependabotCache()
    typealias Loader = @Sendable ([String], String) async throws -> [String]

    struct Result: Sendable {
        let repositories: [String]
        let error: String?
    }

    private struct Entry: Codable {
        let repositories: [String]
        let updatedAt: Date
    }

    private let suite: String?
    init(suite: String? = nil) { self.suite = suite }

    func resolve(
        teams: [String], login: String, force: Bool = false, now: Date = .now,
        loader: Loader = { try await TeamDependabot.discover(teams: $0, login: $1) }
    ) async throws -> Result {
        guard !teams.isEmpty else { return Result(repositories: [], error: nil) }
        let defaults = suite.flatMap(UserDefaults.init(suiteName:)) ?? .standard
        let key = "teamDependabot.v1.\(login.lowercased()).\(teams.sorted().joined(separator: ","))"
        let cached = defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(Entry.self, from: $0) }
        if !force, let cached, now.timeIntervalSince(cached.updatedAt) < 86_400 {
            Diagnostics.record(.cacheHit, metrics: [
                .ageSeconds: max(0, Int(now.timeIntervalSince(cached.updatedAt))),
                .repositories: cached.repositories.count
            ])
            return Result(repositories: cached.repositories, error: nil)
        }
        var metrics: [Diagnostics.Metric: Int] = [.forced: force ? 1 : 0, .teams: teams.count]
        if let cached { metrics[.ageSeconds] = max(0, Int(now.timeIntervalSince(cached.updatedAt))) }
        Diagnostics.record(.cacheMiss, metrics: metrics)
        do {
            let repositories = try await loader(teams, login)
            try Task.checkCancellation()
            defaults.set(try JSONEncoder().encode(Entry(repositories: repositories, updatedAt: now)), forKey: key)
            return Result(repositories: repositories, error: nil)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try Task.checkCancellation()
            Diagnostics.record(.cacheFallback, metrics: [.repositories: cached?.repositories.count ?? 0], error: error)
            return Result(repositories: cached?.repositories ?? [], error: error.localizedDescription)
        }
    }
}
