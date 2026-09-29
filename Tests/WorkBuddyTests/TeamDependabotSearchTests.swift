import Foundation
import Testing
@testable import WorkBuddy

@Suite("Concurrencia de búsquedas de equipos")
struct TeamDependabotSearchTests {
    @Test("La preferencia empieza en dos y limita valores inválidos")
    func preference() throws {
        let suite = "team-concurrency-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(TeamDependabot.searchConcurrency(defaults: defaults) == 2)
        for (stored, expected) in [(-1, 1), (0, 1), (1, 1), (4, 4), (6, 6), (8, 8), (100, 8)] {
            defaults.set(stored, forKey: "performance.teamSearchConcurrency")
            #expect(TeamDependabot.searchConcurrency(defaults: defaults) == expected)
        }
        defaults.set("invalid", forKey: "performance.teamSearchConcurrency")
        #expect(TeamDependabot.searchConcurrency(defaults: defaults) == 2)
    }

    @Test("Respeta el límite y procesa todos los grupos y páginas", arguments: [1, 2, 4, 6, 8])
    func boundedConcurrency(limit: Int) async throws {
        let fixture = TeamSearchFixture(count: 9)
        let task = Task {
            try await TeamDependabot.fetch(
                repositories: fixture.repositories, configuration: .empty, viewer: Viewer(login: "me"),
                concurrency: limit, request: { try await fixture.request($0) }
            )
        }
        defer { task.cancel(); Task { await fixture.releaseAll() } }

        try await fixture.waitForCalls(limit)
        #expect(await fixture.calls.count == limit)
        #expect(await fixture.peak == limit)
        await fixture.releaseAll()
        let prs = try await task.value
        #expect(await fixture.peak == limit)
        #expect(await fixture.calls.count == 10) // Nueve grupos, el primero con dos páginas.
        #expect(prs.count == 11) // Un ID compartido más diez IDs únicos.
        #expect(prs.first?.title == "group-0")
    }

    @Test("Reutiliza un lugar libre y conserva el orden pese a respuestas invertidas")
    func completionOrder() async throws {
        let fixture = TeamSearchFixture(count: 3)
        let task = Task {
            try await TeamDependabot.fetch(
                repositories: fixture.repositories, configuration: .empty, viewer: Viewer(login: "me"),
                concurrency: 2, request: { try await fixture.request($0) }
            )
        }
        defer { task.cancel(); Task { await fixture.releaseAll() } }

        try await fixture.waitForCalls(2)
        #expect(Set(await fixture.calls) == ["0:0", "1:0"])
        await fixture.release("1:0")
        try await fixture.waitForCalls(3)
        #expect(Set(await fixture.calls) == ["0:0", "1:0", "2:0"])
        // El tercer grupo ya arrancó mientras el primero sigue suspendido.
        await fixture.release("2:0")
        await fixture.releaseAll()
        let prs = try await task.value
        #expect(await fixture.peak == 2)
        #expect(prs.map(\.id) == ["shared", "PR_0_0", "PR_0_1", "PR_1_0", "PR_2_0"])
        #expect(prs.first?.title == "group-0")
    }

    @Test("Un error descarta el conjunto de resultados", arguments: [1, 2])
    func failure(limit: Int) async throws {
        let fixture = TeamSearchFixture(count: 3, failureAt: 1)
        await fixture.releaseAll()
        await #expect(throws: GH.Failure.self) {
            try await TeamDependabot.fetch(
                repositories: fixture.repositories, configuration: .empty, viewer: Viewer(login: "me"),
                concurrency: limit, request: { try await fixture.request($0) }
            )
        }
        if limit == 1 {
            #expect(await fixture.calls == ["0:0", "0:1", "1:0"])
        }
    }

    @Test("Cancelar detiene los grupos y páginas pendientes")
    func cancellation() async throws {
        let fixture = TeamSearchFixture(count: 3)
        let task = Task {
            try await TeamDependabot.fetch(
                repositories: fixture.repositories, configuration: .empty, viewer: Viewer(login: "me"),
                concurrency: 2, request: { try await fixture.request($0) }
            )
        }
        defer { task.cancel(); Task { await fixture.releaseAll() } }
        try await fixture.waitForCalls(2)
        task.cancel()
        await fixture.releaseAll()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(Set(await fixture.calls) == ["0:0", "1:0"])
    }

    @Test("Sin repositorios no consulta GitHub")
    func empty() async throws {
        let prs = try await TeamDependabot.fetch(
            repositories: [], configuration: .empty, viewer: Viewer(login: "me")
        ) { _ in
            Issue.record("No debe consultar sin repositorios")
            throw GH.Failure.noAttempts
        }
        #expect(prs.isEmpty)
    }
}

private actor TeamSearchFixture {
    // Cada nombre fuerza un grupo propio sin exceder el máximo de 100 caracteres del repo.
    nonisolated let repositories: [String]
    private let queries: [String]
    private let failureAt: Int?
    private var active = 0
    private var automatic = false
    private var pending: [String: CheckedContinuation<Void, Never>] = [:]
    private(set) var calls: [String] = []
    private(set) var peak = 0

    init(count: Int, failureAt: Int? = nil) {
        repositories = (0..<count).map { "organization/repository-\($0)-" + String(repeating: "x", count: 80) }
        queries = TeamDependabot.searches(repositories: repositories)
        self.failureAt = failureAt
        #expect(queries.count == count)
    }

    func request(_ arguments: [String]) async throws -> Data {
        let query = try #require(arguments.first { $0.hasPrefix("query=") })
        let index = try #require(queries.firstIndex { query.contains($0) })
        let page = arguments.contains("cursor=next") ? 1 : 0
        #expect(arguments.contains("reviewAuthor=me"))
        #expect(query.contains("first: 25"))
        #expect(query.contains("mergeStateStatus"))
        let key = "\(index):\(page)"
        calls.append(key)
        active += 1
        peak = max(peak, active)
        defer { active -= 1 }
        if !automatic {
            await withCheckedContinuation { pending[key] = $0 }
        }
        // Como un proceso gh ya iniciado, puede responder después de cancelar.
        if index == failureAt { throw GH.Failure.noAttempts }
        let more = index == 0 && page == 0
        func node(_ id: String) -> [String: Any] {
            ["id": id, "number": index + 1, "title": "group-\(index)",
             "url": "https://github.com/org/repo/pull/\(index + 1)",
             "repository": ["nameWithOwner": "org/repo"],
             "baseRefName": "main", "headRefName": "feature",
             "updatedAt": "2026-09-04T00:00:00Z"]
        }
        return try JSONSerialization.data(withJSONObject: [
            "data": ["viewer": ["login": "me"], "search": [
                "pageInfo": ["hasNextPage": more, "endCursor": more ? "next" as Any : NSNull()],
                "nodes": [node("shared"), node("PR_\(index)_\(page)")]
            ]]
        ])
    }

    func release(_ key: String) {
        guard let continuation = pending.removeValue(forKey: key) else {
            Issue.record("La solicitud \(key) no está suspendida")
            return
        }
        continuation.resume()
    }

    func releaseAll() {
        automatic = true
        let continuations = Array(pending.values)
        pending.removeAll()
        for continuation in continuations { continuation.resume() }
    }

    // Una regresión a ejecución secuencial debe fallar, no colgar los tests.
    func waitForCalls(_ count: Int) async throws {
        for _ in 0..<200 {
            if calls.count >= count { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw GH.Failure.noAttempts
    }
}
