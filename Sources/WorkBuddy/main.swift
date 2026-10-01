import AppKit

// Modo debug: `WorkBuddy --dump-queue` imprime la cola de review y sale, sin abrir
// la GUI. Sirve para probar la capa de datos desde la terminal.
if CommandLine.arguments.contains("--dump-queue") {
    await DumpQueue.run()
    exit(0)
}

if CommandLine.arguments.contains("--check-notifications") {
    await NotificationCheck.run()
    exit(0)
}

// El ciclo de vida lo maneja AppKit en vez de `@main` + `App` de SwiftUI: así
// tenemos control directo sobre el NSStatusItem y sobre cuándo se abre y cierra
// el panel. El contenido del panel sigue siendo SwiftUI.
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate

// Icono propio en el Dock y en el conmutador de apps, también al correr el binario.
app.setActivationPolicy(.regular)
app.run()
