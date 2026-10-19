import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Owns the menu bar icon and its popover panel.
/// Left click toggles the panel; right click opens the context menu.
@MainActor
final class MenuBarController: NSObject, NSPopoverDelegate {
    /// Grace period after automatic dismissal so the click that moved focus
    /// does not immediately reopen the panel.
    private static let reopenGuard: TimeInterval = 0.3

    private let statusItem: NSStatusItem
    private let popover: NSPopover
    private let store = ReviewQueueStore()
    private let jiraStore = JiraStore()
    private let panelDiagnostics = PanelDiagnostics()
    private lazy var syncScheduler = SyncScheduler { [store, jiraStore] in
        store.refresh(force: true)
        jiraStore.refresh()
    }

    private var resignObserver: NSObjectProtocol?
    private var lastAutoClose: Date = .distantPast
    private var isPinned = false

    override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        popover = NSPopover()
        super.init()

        configureStatusItem()
        store.activity.setPanelVisible(false)
        configurePopover()
        configureApplicationMenu()

        store.onChange = { [weak self] in self?.updateBadge() }
        Task { await store.notifier.refreshAuthorization() }
        syncScheduler.start()

        // --open-panel opens on startup for testing automatic dismissal without clicking.
        if CommandLine.arguments.contains("--open-panel") {
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(400))
                self.showPanel()
            }
        }
    }

    // MARK: - Configuration

    private func configureStatusItem() {
        guard let button = statusItem.button else { return }

        button.image = Self.makeIcon()
        button.imagePosition = .imageOnly
        button.toolTip = "work-buddy"
        button.setAccessibilityLabel("work-buddy")

        // Use one action for both mouse buttons; handleClick distinguishes them.
        button.target = self
        button.action = #selector(handleClick)
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    private func configurePopover() {
        popover.delegate = self
        popover.behavior = .transient // closes automatically when clicking outside
        popover.animates = false // prevent the panel from sliding when opened
        let controller = NSHostingController(
            rootView: PanelView(
                store: store,
                jiraStore: jiraStore,
                onLanguageChange: { [weak self] in
                    self?.updateBadge()
                    self?.configureApplicationMenu()
                },
                onPinChange: { [weak self] isPinned in
                    self?.isPinned = isPinned
                    self?.popover.behavior = isPinned ? .applicationDefined : .transient
                },
                repositoryPickerWindow: { [weak self] in
                    self?.popover.contentViewController?.view.window
                }
            )
        )
        controller.view.setFrameSize(PanelView.preferredSize)
        controller.view.layoutSubtreeIfNeeded()
        popover.contentViewController = controller
        // Assigning the controller replaces contentSize with its view size.
        // Set the size afterward to avoid SwiftUI's provisional initial dimensions.
        popover.contentSize = PanelView.preferredSize
    }

    /// The badge counts actionable PRs from the store's filtered queues.
    private func updateBadge() {
        guard let button = statusItem.button else { return }
        // Explain which action counts contribute to the total.
        button.toolTip = "work-buddy — \(store.actionableSummary)"

        // Changing the title resizes the status item and moves the popover anchor.
        // While open, update the queues but defer the badge until dismissal so the
        // panel does not move under the pointer.
        guard !popover.isShown else { return }
        let count = store.actionableCount
        button.title = count > 0 ? " \(count)" : ""
        button.imagePosition = count > 0 ? .imageLeading : .imageOnly
    }

    // Include transient NSPopover dismissal, which may bypass closePanel().
    // Always use the latest count.
    func popoverDidClose(_ notification: Notification) {
        store.activity.setPanelVisible(false)
        panelDiagnostics.end()
        stopObservingFocusLoss()
        updateBadge()
    }

    func popoverDidShow(_ notification: Notification) {
        store.activity.setPanelVisible(true)
        panelDiagnostics.shown()
    }

    func popoverShouldClose(_ popover: NSPopover) -> Bool {
        !isPinned && !hasModalPanel
    }

    private var hasModalPanel: Bool {
        NSApp.modalWindow != nil || popover.contentViewController?.view.window?.attachedSheet != nil
    }

    private static func makeIcon() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            NSColor.black.set()

            // The gap leaves space around the satellite even at menu bar size.
            let orbit = NSBezierPath()
            orbit.appendArc(withCenter: NSPoint(x: 9, y: 9), radius: 6,
                            startAngle: 70, endAngle: 380)
            orbit.lineWidth = 1.4
            orbit.lineCapStyle = .round
            orbit.stroke()

            NSBezierPath(ovalIn: NSRect(x: 7, y: 7, width: 4, height: 4)).fill()
            NSBezierPath(ovalIn: NSRect(x: 11.1, y: 11.1, width: 4.4, height: 4.4)).fill()
            return true
        }
        image.isTemplate = true // se adapta a barra clara u oscura
        return image
    }

    // MARK: - Clicks

    @objc private func handleClick() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showContextMenu()
            return
        }
        // Clicking the icon can trigger focus-loss dismissal before this handler runs.
        // Without the guard, togglePanel would reopen it and the icon could never close it.
        guard Date().timeIntervalSince(lastAutoClose) > Self.reopenGuard else { return }
        togglePanel()
    }

    private func togglePanel() {
        if popover.isShown {
            closePanel()
        } else {
            showPanel()
        }
    }

    func showPanel() {
        // Reopening from the Dock brings an already-open panel forward without
        // closing it or restarting measurements, including when pinned.
        guard !hasModalPanel else { return }
        if popover.isShown {
            popover.contentViewController?.view.window?.makeKeyAndOrderFront(nil)
            return
        }
        guard let button = statusItem.button else { return }

        panelDiagnostics.begin(hasSnapshot: store.lastUpdated != nil)
        panelDiagnostics.measure(.panelRefresh) { store.refresh() } // no-op si la data es reciente
        // Resolve content and anchor before calculating the initial position.
        // Refresh may change badge width while the panel is closed.
        panelDiagnostics.measure(.panelLayout) {
            button.window?.contentView?.layoutSubtreeIfNeeded()
            popover.contentViewController?.view.layoutSubtreeIfNeeded()
            popover.contentSize = PanelView.preferredSize
        }
        panelDiagnostics.measure(.panelShow) {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }

        // The popover needs explicit keyboard focus for text fields.
        popover.contentViewController?.view.window?.makeKey()

        observeFocusLoss()
    }

    private func closePanel() {
        stopObservingFocusLoss()
        // Explicit menu bar dismissal also works while pinned.
        popover.close()
    }

    // MARK: - Dismiss on focus loss

    /// Transient behavior only handles outside clicks. Command-Tab or activating
    /// another app without clicking used to leave the panel open. Making the popover
    /// window key lets didResignKey signal those focus changes.
    private func observeFocusLoss() {
        guard let window = popover.contentViewController?.view.window else { return }
        stopObservingFocusLoss()

        resignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            // queue: .main guarantees the main thread, but the @Sendable closure
            // does not convey that guarantee to the compiler.
            MainActor.assumeIsolated { self?.autoClose() }
        }
    }

    private func autoClose() {
        guard popover.isShown, !isPinned, !hasModalPanel else { return }

        // An internal menu also resigns the key window and must not dismiss the panel.
        // In measurements, isActive remained true for internal menus and was already
        // false when focus actually moved to another app.
        guard !NSApp.isActive else { return }

        debugLog("closing panel: lost focus")
        lastAutoClose = .now
        closePanel()
    }

    private func stopObservingFocusLoss() {
        guard let resignObserver else { return }
        NotificationCenter.default.removeObserver(resignObserver)
        self.resignObserver = nil
    }

    private func showContextMenu() {
        guard let button = statusItem.button else { return }

        closePanel()

        applicationMenu().popUp(
            positioning: nil,
            at: NSPoint(x: 0, y: button.bounds.height + 4),
            in: button
        )
    }

    private func configureApplicationMenu() {
        let menu = NSMenu()
        let item = NSMenuItem()
        item.submenu = applicationMenu()
        menu.addItem(item)
        NSApp.mainMenu = menu
    }

    private func applicationMenu() -> NSMenu {
        let menu = NSMenu(title: "work-buddy")
        menu.addItem(menuItem(title: L10n.text(.menuAbout), action: #selector(showAbout)))
        menu.addItem(menuItem(title: L10n.text(.menuExportDiagnostics), action: #selector(exportDiagnostics)))
        menu.addItem(.separator())
        menu.addItem(menuItem(title: L10n.text(.menuQuit), action: #selector(quit), keyEquivalent: "q"))

        return menu
    }

    private func menuItem(title: String, action: Selector, keyEquivalent: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        item.target = self
        return item
    }

    // MARK: - Menu actions

    @objc private func exportDiagnostics() {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "work-buddy-diagnostic.txt"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                do {
                    let data = try await DiagnosticLog.exportReport()
                    try data.write(to: url, options: .atomic)
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                } catch {
                    NSAlert(error: error).runModal()
                }
            }
        }
    }

    @objc private func showAbout() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(nil)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
