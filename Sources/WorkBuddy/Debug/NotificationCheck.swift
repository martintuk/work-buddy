import Foundation
import UserNotifications

/// Development-only notification diagnostics. Run the executable inside the .app
/// so Bundle.main resolves and a bundle identifier exists:
///
///     "build/work-buddy.app/Contents/MacOS/WorkBuddy" --check-notifications
enum NotificationCheck {
    @MainActor
    static func run() async {
        guard let identifier = Bundle.main.bundleIdentifier else {
            print("✗ no bundle identifier — run the binary inside the .app")
            return
        }
        print("bundle: \(identifier)")

        let notifier = Notifier()
        do {
            try await notifier.requestAuthorization()
            print("requestAuthorization → granted")
        } catch {
            print("✗ requestAuthorization failed: \(error.localizedDescription)")
            // Enqueuing does not prove macOS will display a notification. Do not send
            // if the authorization flow shared with the UI rejects permission.
            return
        }

        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        print("authorizationStatus: \(describe(settings.authorizationStatus))")
        print("alertSetting: \(settings.alertSetting == .enabled ? "enabled" : "disabled")")

        do {
            try await notifier.sendTest()
            print("✓ test notification queued")
        } catch {
            print("✗ add failed: \(error.localizedDescription)")
        }

        // Allow time for delivery before exiting.
        try? await Task.sleep(for: .seconds(2))
        withExtendedLifetime(notifier) {}
    }

    private static func describe(_ status: UNAuthorizationStatus) -> String {
        switch status {
        case .notDetermined: "notDetermined"
        case .denied: "denied"
        case .authorized: "authorized"
        case .provisional: "provisional"
        @unknown default: "unknown(\(status.rawValue))"
        }
    }
}
