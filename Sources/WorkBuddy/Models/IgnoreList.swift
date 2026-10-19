import Foundation

/// PRs the user chose to hide. Store GitHub's stable global node ID,
/// which survives title and base-branch changes.
@MainActor
@Observable
final class IgnoreList {
    private static let key = "ignoredPullRequestIDs"

    private let defaults: UserDefaults
    private(set) var ids: Set<String>

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        ids = Set(defaults.stringArray(forKey: Self.key) ?? [])
    }

    func contains(_ pullRequest: PullRequest) -> Bool {
        ids.contains(pullRequest.id)
    }

    func ignore(_ pullRequest: PullRequest) {
        guard ids.insert(pullRequest.id).inserted else { return }
        persist()
    }

    func restore(_ pullRequest: PullRequest) {
        guard ids.remove(pullRequest.id) != nil else { return }
        persist()
    }

    // Do not purge closed PR IDs: checking them requires API calls and each costs
    // roughly 50 bytes. Purging against an incomplete current queue could restore
    // ignored PRs simply because one query did not return them.
    private func persist() {
        defaults.set(Array(ids), forKey: Self.key)
    }
}
