import AppKit

// Debug mode: `WorkBuddy --dump-queue` prints the review queue and exits without opening the GUI, for testing the data layer from a terminal.
if CommandLine.arguments.contains("--dump-queue") {
    await DumpQueue.run()
    exit(0)
}

if CommandLine.arguments.contains("--check-notifications") {
    await NotificationCheck.run()
    exit(0)
}

// AppKit manages the lifecycle instead of SwiftUI's `@main` and `App`, providing direct control over NSStatusItem and panel opening and closing. Panel content remains SwiftUI.
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate

// Custom Dock and app-switcher icon, including when running the bare binary.
app.setActivationPolicy(.regular)
app.run()
