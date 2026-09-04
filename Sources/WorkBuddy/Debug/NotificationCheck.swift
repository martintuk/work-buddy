import Foundation
import UserNotifications

/// Diagnóstico de notificaciones. Sólo para desarrollo.
///
/// Hay que correrlo desde el binario **de adentro** del .app, para que
/// `Bundle.main` resuelva al bundle y exista un bundle identifier:
///
///     "build/work-buddy.app/Contents/MacOS/WorkBuddy" --check-notifications
enum NotificationCheck {
    @MainActor
    static func run() async {
        guard let identifier = Bundle.main.bundleIdentifier else {
            print("✗ sin bundle identifier — corré el binario de adentro del .app")
            return
        }
        print("bundle: \(identifier)")

        let notifier = Notifier()
        do {
            try await notifier.requestAuthorization()
            print("requestAuthorization → concedido")
        } catch {
            print("✗ requestAuthorization falló: \(error.localizedDescription)")
            // Encolar no prueba que macOS vaya a mostrarla. No enviamos si
            // el mismo flujo usado por la interfaz rechaza la autorización.
            return
        }

        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        print("authorizationStatus: \(describe(settings.authorizationStatus))")
        print("alertSetting: \(settings.alertSetting == .enabled ? "enabled" : "disabled")")

        do {
            try await notifier.sendTest()
            print("✓ notificación de prueba encolada")
        } catch {
            print("✗ add falló: \(error.localizedDescription)")
        }

        // Le damos tiempo al sistema a entregarla antes de salir.
        try? await Task.sleep(for: .seconds(2))
        withExtendedLifetime(notifier) {}
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
