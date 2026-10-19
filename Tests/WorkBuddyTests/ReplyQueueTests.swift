import Foundation
import Testing

@testable import WorkBuddy

@Suite("Pending conversations")
struct ReplyQueueTests {
    private let mention = "<a class=\"user-mention notranslate\" href=\"https://github.com/me\">@me</a>"

    @Test("Own PRs need replies to the latest external comment; resolving always suffices",
          arguments: [(true, false, false), (true, true, false),
                      (false, true, false), (false, false, true)])
    func authored(resolved: Bool, mine: Bool, expected: Bool) throws {
        let value = try decode(thread(resolved: resolved, comments: [comment(mine: mine)]))
        #expect(value.attention(authoredByMe: true, me: "me") == (expected ? .needsReply : .none))
    }

    @Test("Mentions in others' PRs remain pending after further external comments")
    func pendingMention() throws {
        let value = try decode(thread(comments: [comment(html: mention), comment(html: "Otro mensaje")]))
        #expect(value.attention(authoredByMe: false, me: "me") == .needsReply)
    }

    @Test("Personal replies address earlier mentions and switch to waiting")
    func answeredMention() throws {
        let value = try decode(thread(comments: [comment(html: mention), comment(mine: true)]))
        #expect(value.attention(authoredByMe: false, me: "me") == .waitingForReply)
    }

    @Test("Replies to personal comments require a response even without a mention")
    func answeredByOther() throws {
        let value = try decode(thread(comments: [comment(mine: true), comment()]))
        #expect(value.attention(authoredByMe: false, me: "me") == .needsReply)
    }

    @Test("New mentions after a personal reply require attention again")
    func mentionedAgain() throws {
        let value = try decode(thread(comments: [comment(mine: true), comment(html: mention)]))
        #expect(value.attention(authoredByMe: false, me: "me") == .needsReply)
    }

    @Test("Resolving others' threads clears waiting and mentions",
          arguments: [true, false])
    func resolvedForeign(mine: Bool) throws {
        let value = try decode(thread(resolved: true, comments: [comment(mine: mine, html: mention)]))
        #expect(value.attention(authoredByMe: false, me: "me") == .none)
    }

    @Test("External comments without mentions need no personal reply")
    func unrelated() throws {
        let value = try decode(thread(comments: [comment()]))
        #expect(value.attention(authoredByMe: false, me: "me") == .none)
    }

    @Test("Drafts neither address mentions nor create waiting states")
    func drafts() throws {
        let value = try decode(thread(comments: [comment(html: mention), comment(mine: true, state: "PENDING")]))
        #expect(value.attention(authoredByMe: false, me: "me") == .needsReply)
        let onlyDraft = try decode(thread(comments: [comment(mine: true, state: "PENDING")]))
        #expect(onlyDraft.attention(authoredByMe: false, me: "me") == .none)
    }

    @Test("Mentions respect exact identity and rendered HTML")
    func mentions() throws {
        for html in ["<code>@me</code>", "name@me.com", "@me", mention.replacingOccurrences(of: "@me<", with: "@me-other<"),
                     "<a class=\"team-mention\">@org/me</a>"] {
            #expect(try decode(thread(comments: [comment(html: html)]))
                .attention(authoredByMe: false, me: "me") == .none)
        }
        #expect(try decode(thread(comments: [comment(html: mention.uppercased())]))
            .attention(authoredByMe: false, me: "me") == .needsReply)
    }

    @Test("Paginate own threads and stop at the first pending item")
    func threadPagination() async throws {
        let own = try pullRequest(1)
        var calls = 0
        let result = try await ReplyQueue.fetch(for: [own], me: "me") { args in
            calls += 1
            if calls == 1 {
                return try response(["pr0": node("PR_1", threads: Array(
                    repeating: thread(resolved: true, comments: [comment()]), count: 50
                ), next: "page2")])
            }
            #expect(args.contains("cursor0=page2"))
            return try response(["pr0": node("PR_1", threads: [thread(comments: [comment()])], next: "page3")])
        }
        #expect(calls == 2)
        #expect(result.needingReply.map(\.id) == [own.id])
        #expect(result.waitingForReply.isEmpty)
    }

    @Test("Find mentions beyond the latest 20 comments")
    func commentPagination() async throws {
        let other = try pullRequest(1, author: "other")
        var calls = 0
        let result = try await ReplyQueue.fetch(for: [other], me: "me") { args in
            calls += 1
            if calls == 1 {
                return try response(["pr0": node("PR_1", threads: [
                    thread(comments: Array(repeating: comment(), count: 20), previous: "older")
                ])])
            }
            #expect(args.contains("id0=THREAD_1"))
            #expect(args.contains("cursor0=older"))
            return try response(["pr0": thread(comments: [comment(html: mention)])])
        }
        #expect(calls == 2)
        #expect(result.needingReply.map(\.id) == [other.id])
        #expect(result.waitingForReply.isEmpty)
    }

    @Test("Personal comments on older pages followed by external replies require a response")
    func olderOwnComment() async throws {
        var calls = 0
        let result = try await ReplyQueue.fetch(for: [pullRequest(1, author: "other")], me: "me") { _ in
            calls += 1
            if calls == 1 {
                return try response(["pr0": node("PR_1", threads: [thread(comments: [comment()], previous: "older")])])
            }
            return try response(["pr0": thread(comments: [comment(mine: true)])])
        }
        #expect(result.needingReply.count == 1)
        #expect(result.waitingForReply.isEmpty)
    }

    @Test("Draft-only pages allow querying the last published comment")
    func draftPagination() async throws {
        var calls = 0
        let result = try await ReplyQueue.fetch(for: [pullRequest(1, author: "other")], me: "me") { _ in
            calls += 1
            if calls == 1 {
                return try response(["pr0": node("PR_1", threads: [
                    thread(comments: [comment(mine: true, state: "PENDING")], previous: "older")
                ])])
            }
            return try response(["pr0": thread(comments: [comment(mine: true)])])
        }
        #expect(result.waitingForReply.count == 1)
        #expect(result.needingReply.isEmpty)
    }

    @Test("A PR can have separate threads needing replies and awaiting responses")
    func bothCategories() async throws {
        var calls = 0
        let pr = try pullRequest(1, author: "other")
        let result = try await ReplyQueue.fetch(for: [pr], me: "me") { _ in
            calls += 1
            if calls == 1 {
                return try response(["pr0": node("PR_1", threads: [thread(comments: [comment(mine: true)])], next: "more")])
            }
            return try response(["pr0": node("PR_1", threads: [thread(comments: [comment(html: mention)])])])
        }
        #expect(calls == 2)
        #expect(result.needingReply.map(\.id) == [pr.id])
        #expect(result.waitingForReply.map(\.id) == [pr.id])
    }

    @Test("Query multiple PRs per request, split batches, and deduplicate")
    func batching() async throws {
        let prs = try (1...26).map { try pullRequest($0) }
        var batchSizes: [Int] = []
        let result = try await ReplyQueue.fetch(for: prs + [prs[0]], me: "me") { args in
            let ids = args.filter { $0.hasPrefix("id") && $0.contains("=PR_") }
            batchSizes.append(ids.count)
            var nodes: [String: Any] = [:]
            for (index, argument) in ids.enumerated() {
                nodes["pr\(index)"] = node(String(argument.split(separator: "=")[1]), threads: [thread(comments: [comment()])])
            }
            return try response(nodes)
        }
        #expect(batchSizes == [10, 10, 6])
        #expect(Set(result.needingReply.map(\.id)) == Set(prs.map(\.id)))
    }

    @Test("Incomplete responses fail instead of reporting everything addressed")
    func missingNode() async throws {
        let pr = try pullRequest(1)
        await #expect(throws: GH.Failure.self) {
            _ = try await ReplyQueue.fetch(for: [pr], me: "me") { _ in try response(["pr0": NSNull()]) }
        }
    }

    @Test("No candidates means no GitHub queries")
    func empty() async throws {
        let result = try await ReplyQueue.fetch(for: [], me: "me") { _ in
            Issue.record("Must not query GitHub")
            return Data()
        }
        #expect(result.needingReply.isEmpty && result.waitingForReply.isEmpty)
    }

    @Test("Search includes mentions and personal reviews without requiring review requests")
    func discoveryScope() {
        #expect(ConversationCandidates.searches.contains { $0.contains("involves:@me") })
        #expect(ConversationCandidates.searches.contains { $0.contains("reviewed-by:@me") })
        for query in ConversationCandidates.searches {
            #expect(query.contains("is:open is:pr -author:@me"))
            #expect(!query.contains("review-requested:"))
        }
    }

    private func comment(mine: Bool = false, html: String = "Un comentario", state: String = "SUBMITTED") -> [String: Any] {
        ["viewerDidAuthor": mine, "bodyHTML": html, "state": state]
    }

    private func thread(resolved: Bool = false, comments: [[String: Any]], previous: String? = nil) -> [String: Any] {
        ["id": "THREAD_1", "isResolved": resolved, "comments": ["nodes": comments,
         "pageInfo": ["hasPreviousPage": previous != nil, "startCursor": previous as Any? ?? NSNull()]]]
    }

    private func decode(_ value: [String: Any]) throws -> ReplyQueue.Thread {
        try JSONDecoder().decode(ReplyQueue.Thread.self, from: JSONSerialization.data(withJSONObject: value))
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
