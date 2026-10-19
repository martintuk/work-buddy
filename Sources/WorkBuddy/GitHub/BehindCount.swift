import Foundation

/// Commits each PR branch is behind its base.
///
/// mergeStateStatus reports BEHIND only when the repository requires up-to-date
/// branches. A branch ten commits behind may still read BLOCKED. In a sample of
/// 20 Dependabot PRs, that flag identified only one of four outdated branches.
///
/// REST comparison returned the full diff (27 KB per PR); per_page did not reduce
/// the dominant files payload. GraphQL Ref.compare returns just the count and
/// supports aliases: 820 bytes in one request for 20 PRs versus 540 KB in twenty.
enum BehindCount {
    /// Comparisons per request. Twenty took roughly 3.8 seconds,
    /// so this runs after queue loading rather than blocking panel display.
    static let batchSize = 20

    /// Returns behindBy by PR ID. A missing key means unmeasured,
    /// not zero (up to date); preserving that distinction matters for rebase decisions.
    static func fetch(for pullRequests: [PullRequest]) async -> [String: Int] {
        var results: [String: Int] = [:]
        let comparable = pullRequests.filter {
            isSafeRef($0.baseRefName) && isSafeRef($0.headRefName)
        }

        for batch in comparable.chunked(into: batchSize) {
            Diagnostics.record(.counts, metrics: [.batchSize: batch.count, .pages: 1])
            guard let data = try? await GH.runRetrying(
                ["api", "graphql", "-f", "query=\(query(for: batch))"]
            ) else {
                // Leave failed batches unmeasured and show that in the UI rather than reporting zero.
                continue
            }
            guard let response = try? JSONDecoder.github.decode(BatchResponse.self, from: data)
            else { continue }

            // GraphQL can return partial data with errors, for example for an archived repository.
            // Keep the comparisons it successfully resolved.
            for (index, pullRequest) in batch.enumerated() {
                if let behind = response.data?["p\(index)"]??.ref?.compare?.behindBy {
                    results[pullRequest.id] = behind
                }
            }
        }
        Diagnostics.record(.counts, metrics: [.candidates: comparable.count, .items: results.count])
        if results.count < comparable.count { Diagnostics.record(.partial) }
        return results
    }

    /// One repository alias per PR in a single request.
    static func query(for pullRequests: [PullRequest]) -> String {
        let fields = pullRequests.enumerated().map { index, pullRequest in
            let parts = pullRequest.repository.split(separator: "/", maxSplits: 1)
            let owner = parts.first.map(String.init) ?? ""
            let name = parts.count > 1 ? String(parts[1]) : ""
            return """
            p\(index): repository(owner: "\(owner)", name: "\(name)") {
              ref(qualifiedName: "\(pullRequest.baseRefName)") {
                compare(headRef: "\(pullRequest.headRefName)") { behindBy }
              }
            }
            """
        }
        return "query {\n\(fields.joined(separator: "\n"))\n}"
    }

    /// Check the expected ref restrictions before GraphQL interpolation.
    /// If an unsupported quote, backslash, or space appears, leave it unmeasured
    /// rather than sending a malformed query.
    static func isSafeRef(_ ref: String) -> Bool {
        !ref.isEmpty && !ref.contains { "\"\\ \n\t\r".contains($0) }
    }
}

// MARK: - Response

/// Aliases are dynamic keys (p0, p1, ...), so decode data as a dictionary
/// instead of a structure with fixed fields.
private struct BatchResponse: Decodable {
    let data: [String: Entry?]?

    struct Entry: Decodable {
        let ref: Ref?

        struct Ref: Decodable {
            let compare: Comparison?

            struct Comparison: Decodable {
                let behindBy: Int
            }
        }
    }
}

private extension Array {
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return [self] }
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0 ..< Swift.min($0 + size, count)])
        }
    }
}
