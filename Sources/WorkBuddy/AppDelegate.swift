import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var menuBar: MenuBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        menuBar = MenuBarController()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Finder y el Dock deben abrir el panel aunque la app ya esté corriendo.
        menuBar?.showPanel()
        return false
    }

    // El panel se crea al abrirlo; no hay ventanas que restaurar.
    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }
}
