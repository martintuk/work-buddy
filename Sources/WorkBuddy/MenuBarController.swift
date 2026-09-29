import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Dueño del icono en la barra de menú y del panel que se despliega al clickearlo.
///
/// Click izquierdo abre/cierra el panel. Click derecho abre un menú contextual
/// (la app no tiene icono en el Dock, así que el menú es la salida de emergencia).
@MainActor
final class MenuBarController: NSObject, NSPopoverDelegate {
    /// Ventana de gracia tras un cierre automático, para que el click que hizo
    /// perder el foco no vuelva a abrir el panel.
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
        configurePopover()

        store.onChange = { [weak self] in self?.updateBadge() }
        Task { await store.notifier.refreshAuthorization() }
        syncScheduler.start()

        // `--open-panel` abre el panel al arrancar, para poder probar el cierre
        // automático sin clickear.
        if CommandLine.arguments.contains("--open-panel") {
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(400))
                self.showPanel()
            }
        }
    }

    // MARK: - Configuración

    private func configureStatusItem() {
        guard let button = statusItem.button else { return }

        button.image = Self.makeIcon()
        button.imagePosition = .imageOnly
        button.toolTip = "work-buddy"
        button.setAccessibilityLabel("work-buddy")

        // Un único action para los dos botones; los separamos en handleClick().
        button.target = self
        button.action = #selector(handleClick)
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    private func configurePopover() {
        popover.delegate = self
        popover.behavior = .transient // se cierra solo al clickear afuera
        popover.animates = false // sin esto el panel "resbala" al abrirse
        let controller = NSHostingController(
            rootView: PanelView(
                store: store,
                jiraStore: jiraStore,
                onLanguageChange: { [weak self] in self?.updateBadge() },
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
        // Asignar el controller reemplaza contentSize por el tamaño de su vista.
        // Fijarlo después evita usar un tamaño inicial provisional de SwiftUI.
        popover.contentSize = PanelView.preferredSize
    }

    /// El badge cuenta todo lo que espera una acción tuya: lo que tenés que
    /// revisar más lo que podés mergear. Los PRs de bots que esperan review no
    /// entran — si el badge contara ruido, dejarías de mirarlo.
    private func updateBadge() {
        guard let button = statusItem.button else { return }
        // El número solo no dice de qué se compone, ahora que suma dos cosas.
        button.toolTip = "work-buddy — \(store.actionableSummary)"

        // Cambiar el título cambia el ancho del status item y mueve el ancla
        // del popover. Mientras está abierto, la cola se actualiza en vivo y
        // el badge espera al cierre para no desplazar el panel bajo el mouse.
        guard !popover.isShown else { return }
        let count = store.actionableCount
        button.title = count > 0 ? " \(count)" : ""
        button.imagePosition = count > 0 ? .imageLeading : .imageOnly
    }

    // Incluye el cierre automático de NSPopover (.transient), que no pasa
    // necesariamente por closePanel(). Se usa siempre el último contador.
    func popoverDidClose(_ notification: Notification) {
        panelDiagnostics.end()
        stopObservingFocusLoss()
        updateBadge()
    }

    func popoverDidShow(_ notification: Notification) {
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

            // El corte deja aire alrededor del satélite incluso a tamaño de menú.
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
        // Clickear el icono con el panel abierto le hace perder el foco, así que
        // el cierre automático ya corrió y `popover.isShown` es false. Sin esta
        // guarda, `togglePanel` lo volvería a abrir y el icono no cerraría nunca.
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

    private func showPanel() {
        guard let button = statusItem.button else { return }

        panelDiagnostics.begin(hasSnapshot: store.lastUpdated != nil)
        panelDiagnostics.measure(.panelRefresh) { store.refresh() } // no-op si la data es reciente
        // Resolver el contenido y el ancla antes de calcular la primera posición.
        // El refresh puede cambiar el ancho del badge mientras el panel está cerrado.
        panelDiagnostics.measure(.panelLayout) {
            button.window?.contentView?.layoutSubtreeIfNeeded()
            popover.contentViewController?.view.layoutSubtreeIfNeeded()
            popover.contentSize = PanelView.preferredSize
        }
        panelDiagnostics.measure(.panelShow) {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }

        // Al ser una app .accessory el panel no recibe foco de teclado por su
        // cuenta; sin esto los campos de texto que agreguemos no van a andar.
        popover.contentViewController?.view.window?.makeKey()

        observeFocusLoss()
    }

    private func closePanel() {
        stopObservingFocusLoss()
        // El cierre explícito desde el menubar también funciona con el pin activo.
        popover.close()
    }

    // MARK: - Cierre al perder el foco

    /// `.transient` sólo cubre clicks fuera del panel: con cmd-tab, o al activar
    /// otra app sin clickear, el panel quedaba abierto. La ventana del popover es
    /// key porque la hacemos key al mostrarla, así que su `didResignKey` es la
    /// señal de "perdí el foco".
    private func observeFocusLoss() {
        guard let window = popover.contentViewController?.view.window else { return }
        stopObservingFocusLoss()

        resignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            // `queue: .main` garantiza el hilo principal, pero el closure es
            // @Sendable y el compilador no lo sabe.
            MainActor.assumeIsolated { self?.autoClose() }
        }
    }

    private func autoClose() {
        guard popover.isShown, !isPinned, !hasModalPanel else { return }

        // Un menú abierto *dentro* del panel también hace que la ventana resigne
        // key, y ahí no hay que cerrar nada. La app distingue los dos casos:
        // medido, con el panel enfocado `isActive` es true, y cuando el foco se
        // va de verdad llega acá ya en false.
        guard !NSApp.isActive else { return }

        debugLog("cierro el panel: perdió el foco")
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

        let menu = NSMenu()
        menu.addItem(menuItem(title: L10n.text(.menuAbout), action: #selector(showAbout)))
        menu.addItem(menuItem(title: L10n.text(.menuExportDiagnostics), action: #selector(exportDiagnostics)))
        menu.addItem(.separator())
        menu.addItem(menuItem(title: L10n.text(.menuQuit), action: #selector(quit), keyEquivalent: "q"))

        menu.popUp(
            positioning: nil,
            at: NSPoint(x: 0, y: button.bounds.height + 4),
            in: button
        )
    }

    private func menuItem(title: String, action: Selector, keyEquivalent: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        item.target = self
        return item
    }

    // MARK: - Acciones del menú

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
