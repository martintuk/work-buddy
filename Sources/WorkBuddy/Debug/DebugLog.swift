import Foundation

/// Log to stderr only when WORK_BUDDY_DEBUG=1.
/// Run the executable inside the .app from Terminal to see stderr:
///
///     WORK_BUDDY_DEBUG=1 "build/work-buddy.app/Contents/MacOS/WorkBuddy"
func debugLog(_ message: @autoclosure () -> String) {
    guard ProcessInfo.processInfo.environment["WORK_BUDDY_DEBUG"] == "1" else { return }
    FileHandle.standardError.write(Data("[work-buddy] \(message())\n".utf8))
}
