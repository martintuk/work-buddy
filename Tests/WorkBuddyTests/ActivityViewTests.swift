import AppKit
import SwiftUI
import Testing
@testable import WorkBuddy

@Suite("Presentación de actividad")
@MainActor
struct ActivityViewTests {
    @Test("Render de actividad con errores, omisiones y operaciones en curso")
    func renderActivity() throws {
        guard let directory = ProcessInfo.processInfo.environment["ACTIVITY_SNAPSHOTS"] else { return }
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let log = ActivityLog()
        log.record(.merge, on: fixture(1))
        log.record(PullRequestBatch.Entry(candidate: .init(pullRequest: fixture(2), action: .approve),
            status: .skipped(.changed)), source: .batch)
        log.record(PullRequestBatch.Entry(candidate: .init(pullRequest: fixture(3), action: .merge),
            status: .failed(LocalizedMessage("GitHub rechazó la acción porque la rama cambió durante la operación. Reintentá con los datos actualizados."))), source: .autopilot)
        log.record(PullRequestBatch.Entry(candidate: .init(pullRequest: fixture(4), action: .approve),
            status: .waiting(seconds: 30, attempt: 2)), source: .autopilot)
        log.record(.dependabotRebase, on: fixture(5), status: .running)
        log.record(.merge, on: fixture(6), status: .uncertain(LocalizedMessage("Connection lost")), viewer: "me")
        for scheme in [ColorScheme.light, .dark] {
            let content = ActivityView(activity: log)
                .frame(width: 420, height: 480).environment(\.colorScheme, scheme)
            try render(content, size: NSSize(width: 420, height: 480), scheme: scheme,
                       path: "\(directory)/activity-\(scheme).png")
            let store = ReviewQueueStore.preview(reviews: [], merges: [])
            store.autopilot.enable([], viewer: "me", operations: .init(
                read: { _, _ in fatalError("Sin candidatos") }, write: { _ in fatalError("Sin escrituras") }))
            try render(VStack(spacing: 0) {
                ActivityView(activity: log)
                PullRequestExecutionControls(store: store, compact: true)
            }.frame(width: 420, height: 480), size: NSSize(width: 420, height: 480), scheme: scheme,
                path: "\(directory)/activity-with-autopilot-\(scheme).png")
            store.autopilot.stop()
            try render(PanelView(store: ReviewQueueStore.preview(reviews: [fixture(1)], merges: []), jiraStore: JiraStore())
                .environment(\.colorScheme, scheme), size: PanelView.preferredSize, scheme: scheme,
                path: "\(directory)/panel-\(scheme).png")
        }
    }

    private func render<V: View>(_ content: V, size: NSSize, scheme: ColorScheme, path: String) throws {
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
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        try data.write(to: URL(fileURLWithPath: path))
    }
}
