import Foundation
import Testing

@testable import WorkBuddy

@Suite("PRs para responder")
struct ReplyQueueTests {
    @Test("Resolver alcanza, y sólo importa quién comentó último",
          arguments: [(true, false, false), (true, true, false),
                      (false, true, false), (false, false, true)])
    func classification(resolved: Bool, mine: Bool, expected: Bool) throws {
        let data = try JSONSerialization.data(withJSONObject: thread(resolved: resolved, mine: mine))
        #expect(try JSONDecoder().decode(ReplyQueue.Thread.self, from: data).needsReply == expected)
    }

    @Test("Pagina hilos y deja de consultar el PR apenas encuentra un pendiente")
    func pagination() async throws {
        let own = try pullRequest(1)
        let other = try pullRequest(2, author: "other")
        var calls = 0
        let result = try await ReplyQueue.fetch(for: [own, other]) { args in
            calls += 1
            #expect(args.contains("id0=PR_1"))
            #expect(!args.contains("id1=PR_2"))
            if calls == 1 {
                return try response(["pr0": node("PR_1", threads: Array(
                    repeating: thread(resolved: true, mine: false), count: 100
                ), next: "page2")])
            }
            #expect(calls == 2)
            #expect(args.contains("cursor0=page2"))
            // Una respuesta anterior no oculta un comentario ajeno posterior.
            return try response(["pr0": node("PR_1", threads: [
                thread(resolved: false, mine: true), thread(resolved: false, mine: false)
            ], next: "page3")])
        }
        #expect(calls == 2)
        #expect(result.map(\.id) == [own.id])
    }

    @Test("Consulta varios PRs por request y divide lotes grandes")
    func batching() async throws {
        let prs = try (1...26).map { try pullRequest($0) }
        var batchSizes: [Int] = []
        let result = try await ReplyQueue.fetch(for: prs) { args in
            let ids = args.filter { $0.hasPrefix("id") && $0.contains("=PR_") }
            batchSizes.append(ids.count)
            var nodes: [String: Any] = [:]
            for (index, argument) in ids.enumerated() {
                let id = String(argument.split(separator: "=")[1])
                nodes["pr\(index)"] = node(id, threads: [thread(resolved: false, mine: false)])
            }
            return try response(nodes)
        }
        #expect(batchSizes == [25, 1])
        #expect(Set(result.map(\.id)) == Set(prs.map(\.id)))
    }

    @Test("Hilos resueltos, respondidos o inexistentes no agregan el PR")
    func noPending() async throws {
        let result = try await ReplyQueue.fetch(for: [pullRequest(1), pullRequest(2)]) { _ in
            try response([
                "pr0": node("PR_1", threads: [thread(resolved: true, mine: false),
                                               thread(resolved: false, mine: true)]),
                "pr1": node("PR_2", threads: [])
            ])
        }
        #expect(result.isEmpty)
    }

    @Test("Una respuesta incompleta falla en lugar de indicar que está todo atendido")
    func missingNode() async throws {
        let pr = try pullRequest(1)
        await #expect(throws: GH.Failure.self) {
            _ = try await ReplyQueue.fetch(for: [pr]) { _ in try response(["pr0": NSNull()]) }
        }
    }

    @Test("Sin PRs propios no consulta GitHub")
    func noAuthored() async throws {
        let result = try await ReplyQueue.fetch(for: [pullRequest(1, author: "other")]) { _ in
            Issue.record("No debería consultar GitHub")
            return Data()
        }
        #expect(result.isEmpty)
    }

    private func thread(resolved: Bool, mine: Bool) -> [String: Any] {
        ["isResolved": resolved, "comments": ["nodes": [["viewerDidAuthor": mine]]]]
    }

    private func node(_ id: String, threads: [[String: Any]], next: String? = nil) -> [String: Any] {
        ["id": id, "reviewThreads": ["nodes": threads,
         "pageInfo": ["hasNextPage": next != nil, "endCursor": next as Any? ?? NSNull()]]]
    }

    private func response(_ nodes: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["data": nodes])
    }

    private func pullRequest(_ number: Int, author: String = "me") throws -> PullRequest {
        let data = try JSONSerialization.data(withJSONObject: [
            "id": "PR_\(number)", "number": number, "title": "Un cambio",
            "url": "https://github.com/org/repo/pull/\(number)",
            "repository": ["nameWithOwner": "org/repo"],
            "baseRefName": "main", "headRefName": "feature",
            "updatedAt": "2026-09-04T00:00:00Z", "author": ["login": author]
        ])
        return try #require(JSONDecoder.github.decode(PullRequestNode.self, from: data).toPullRequest(me: "me"))
    }
}
