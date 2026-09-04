import Foundation
import UserNotifications

/// Diagnóstico de notificaciones. Sólo para desarrollo.
///
/// Hay que correrlo desde el binario **de adentro** del .app, para que
/// `Bundle.main` resuelva al bundle y exista un bundle identifier:
///
///     "build/work-buddy.app/Contents/MacOS/WorkBuddy" --check-notifications
enum NotificationCheck {
    static func run() async {
        guard let identifier = Bundle.main.bundleIdentifier else {
            print("✗ sin bundle identifier — corré el binario de adentro del .app")
            return
        }
        print("bundle: \(identifier)")

        let center = UNUserNotificationCenter.current()
        do {
            let granted = try await center.requestAuthorization(options: [.alert, .sound])
            print("requestAuthorization → \(granted ? "concedido" : "denegado")")
        } catch {
            print("✗ requestAuthorization falló: \(error.localizedDescription)")
        }

        let settings = await center.notificationSettings()
        print("authorizationStatus: \(describe(settings.authorizationStatus))")
        print("alertSetting: \(settings.alertSetting == .enabled ? "enabled" : "disabled")")

        let content = UNMutableNotificationContent()
        content.title = "work-buddy"
        content.body = "Notificación de prueba"
        content.sound = .default
        do {
            try await center.add(
                UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
            )
            print("✓ notificación de prueba encolada")
        } catch {
            print("✗ add falló: \(error.localizedDescription)")
        }

        // Le damos tiempo al sistema a entregarla antes de salir.
        try? await Task.sleep(for: .seconds(2))
    }

    private static func describe(_ status: UNAuthorizationStatus) -> String {
        switch status {
        case .notDetermined: "notDetermined"
        case .denied: "denied"
        case .authorized: "authorized"
        case .provisional: "provisional"
        @unknown default: "desconocido(\(status.rawValue))"
        }
    }
}
