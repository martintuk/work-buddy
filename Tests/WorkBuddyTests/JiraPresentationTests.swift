import AppKit
import SwiftUI
import Testing
@testable import WorkBuddy

@Suite("Presentación de Jira experimental")
@MainActor
struct JiraPresentationTests {
    @Test("Render de GitHub sin tabs, tabs con Jira y configuración experimental")
    func snapshots() throws {
        guard let directory = ProcessInfo.processInfo.environment["JIRA_SNAPSHOTS"] else { return }
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let suite = "jira-presentation-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let github = ReviewQueueStore.preview(reviews: [], merges: [])
        let disabled = JiraStore(defaults: defaults)
        try render(PanelView(store: github, jiraStore: disabled), size: PanelView.preferredSize,
                   path: "\(directory)/github-only.png")
        var config = JiraConfiguration()
        config.isEnabled = true
        try config.persist(defaults: defaults)
        let enabled = JiraStore(defaults: defaults)
        try render(PanelView(store: github, jiraStore: enabled), size: PanelView.preferredSize,
                   path: "\(directory)/github-jira.png")
        for scheme in [ColorScheme.light, .dark] {
            try render(ConfigurationView(store: github, jiraStore: enabled)
                .frame(width: 420, height: 480)
                .background(Color(nsColor: .windowBackgroundColor))
                .environment(\.colorScheme, scheme), size: NSSize(width: 420, height: 480),
                       path: "\(directory)/settings-home-\(scheme).png", scheme: scheme)
            try render(VStack(spacing: 0) {
                SubsectionHeader(title: "Jira", onBack: {})
                ScrollView { JiraSettingsView(store: enabled).padding(16) }
            }
                .frame(width: 420, height: 480)
                .background(Color(nsColor: .windowBackgroundColor))
                .environment(\.colorScheme, scheme), size: NSSize(width: 420, height: 480),
                       path: "\(directory)/jira-settings-\(scheme).png", scheme: scheme)
        }
    }

    private func render<V: View>(_ content: V, size: NSSize, path: String,
                                scheme: ColorScheme = .light) throws {
        let view = NSHostingView(rootView: content)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: .borderless,
                              backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        window.contentView = view
        view.setFrameSize(size)
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try #require(bitmap.representation(using: .png, properties: [:]))
            .write(to: URL(fileURLWithPath: path))
    }
}
