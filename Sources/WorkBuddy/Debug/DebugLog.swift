import Foundation

/// Log a stderr, sólo cuando `WORK_BUDDY_DEBUG=1`.
///
/// Para verlo hay que correr el binario de adentro del .app desde la terminal:
/// lanzada con `open`, la app no tiene stderr a la vista.
///
///     WORK_BUDDY_DEBUG=1 "build/work-buddy.app/Contents/MacOS/WorkBuddy"
func debugLog(_ message: @autoclosure () -> String) {
    guard ProcessInfo.processInfo.environment["WORK_BUDDY_DEBUG"] == "1" else { return }
    FileHandle.standardError.write(Data("[work-buddy] \(message())\n".utf8))
}
