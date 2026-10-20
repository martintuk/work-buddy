import AppKit
import SwiftUI

/// Documentation captures use production views and in-memory, fictional PRs.
/// This entry point does not create AppDelegate or start refreshes or actions.
@main
struct DocumentationScreenshots {
    @MainActor
    static func main() throws {
        _ = NSApplication.shared
        let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let suite = "work-buddy-screenshots-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(false, forKey: "appearance.showEmptySections")
        defaults.set("automation,ignored", forKey: "github.collapsedSections")
        Localization.shared.setLanguage(.english, defaults: defaults)

        let store = ReviewQueueStore.preview(
            reviews: [
                pr(128, title: "Add keyboard shortcuts to search", repository: "acme/desktop",
                   author: "alex", additions: 86, deletions: 12),
                pr(73, title: "Keep filters when switching projects", repository: "acme/api",
                   author: "sam", additions: 34, deletions: 8),
                pr(129, title: "Show progress during file uploads", repository: "acme/desktop",
                   author: "jordan", additions: 52, deletions: 9),
                pr(74, title: "Bump swift-log to the latest version", repository: "acme/api",
                   author: "dependabot", checks: .pending, additions: 4, deletions: 4)
            ],
            merges: [
                pr(126, title: "Restore window position on launch", repository: "acme/desktop",
                   author: "me", ready: true, additions: 28, deletions: 6),
                pr(72, title: "Bump swift-collections to the latest version", repository: "acme/api",
                   author: "dependabot", ready: true, additions: 6, deletions: 6)
            ])
        let jira = JiraStore(defaults: defaults)
        for scheme in [ColorScheme.light, .dark] {
            let content = PanelView(store: store, jiraStore: jira)
                .environment(\.colorScheme, scheme)
                .defaultAppStorage(defaults)
            let view = NSHostingView(rootView: content)
            let window = NSWindow(
                contentRect: NSRect(origin: .zero, size: PanelView.preferredSize),
                styleMask: .borderless, backing: .buffered, defer: false)
            let appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)!
            window.appearance = appearance
            window.contentView = view
            view.setFrameSize(PanelView.preferredSize)
            view.layoutSubtreeIfNeeded()
            view.displayIfNeeded()
            guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
                throw CaptureError.bitmap
            }
            appearance.performAsCurrentDrawingAppearance {
                view.cacheDisplay(in: view.bounds, to: bitmap)
            }
            guard let png = bitmap.representation(using: .png, properties: [:]) else {
                throw CaptureError.png
            }
            let destination = directory.appendingPathComponent("pull-request-queue-\(scheme).png")
            try png.write(to: destination)
            print(destination.path)
        }
    }

    private enum CaptureError: Error { case bitmap, png }

    private static func pr(_ number: Int, title: String, repository: String,
                           author: String, ready: Bool = false, checks: CheckState = .success,
                           additions: Int, deletions: Int) -> PullRequest {
        PullRequest(
            id: "documentation-\(number)", number: number, title: title,
            url: URL(string: "https://github.com/\(repository)/pull/\(number)")!,
            repository: repository, baseRefName: "main", headRefName: "example-\(number)",
            author: Author(login: author, typename: author == "dependabot" ? "Bot" : "User"),
            updatedAt: .now.addingTimeInterval(-Double(number % 8 + 1) * 3_600),
            isDraft: false, checks: checks,
            reviewDecision: ready ? .approved : .reviewRequired,
            mergeable: .mergeable, mergeStateStatus: ready ? .clean : .blocked,
            defaultMergeMethod: .squash, authoredByMe: author == "me",
            requestedFromMe: author != "me", reviewedByMe: false,
            approvals: ready ? 1 : 0, approvedByMe: false,
            headRefOID: "documentation-commit-\(number)", additions: additions, deletions: deletions)
    }
}
