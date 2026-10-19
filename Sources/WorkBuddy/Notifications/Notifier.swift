import AppKit
import Observation
import UserNotifications

/// Manage macOS permissions and deliver individual notifications.
@MainActor
@Observable
final class Notifier: NSObject {
    private static let enabledKey = "notifier.isEnabled"

    private let defaults = UserDefaults.standard

    /// `nil` when running without an app bundle, such as the bare binary in `.build/`. Requesting the notification center without a bundle identifier crashes rather than returning a recoverable error.
    private let center: UNUserNotificationCenter?

    private(set) var authorizationStatus: UNAuthorizationStatus?
    private(set) var isEnabled = UserDefaults.standard.bool(forKey: enabledKey)

    var isAvailable: Bool { center != nil }
    var isAuthorized: Bool {
        authorizationStatus == .authorized || authorizationStatus == .provisional
    }

    enum NotificationError: LocalizedError {
        case unavailable
        case permissionRequired

        var errorDescription: String? {
            switch self {
            case .unavailable: L10n.text(.notificationsUnavailable)
            case .permissionRequired:
                L10n.text(.notificationsDenied)
            }
        }
    }

    override init() {
        center = Bundle.main.bundleIdentifier == nil ? nil : .current()
        super.init()
        center?.delegate = self
    }

    func refreshAuthorization() async {
        authorizationStatus = await center?.notificationSettings().authorizationStatus
    }

    func requestAuthorization() async throws {
        guard let center else { throw NotificationError.unavailable }
        await refreshAuthorization()
        if isAuthorized { return }
        guard authorizationStatus != .denied else { throw NotificationError.permissionRequired }
        do {
            _ = try await center.requestAuthorization(options: [.alert, .sound])
        } catch {
            await refreshAuthorization()
            if authorizationStatus == .denied { throw NotificationError.permissionRequired }
            throw error
        }
        await refreshAuthorization()
        guard isAuthorized else { throw NotificationError.permissionRequired }
    }

    func setEnabled(_ enabled: Bool) async throws {
        if enabled {
            try await requestAuthorization()
        }
        isEnabled = enabled
        defaults.set(enabled, forKey: Self.enabledKey)
    }

    func sendTest() async throws {
        // The explicit test does not change automatic notification preferences.
        try await requestAuthorization()
        try await send(title: "work-buddy", body: L10n.text(.notificationsTestBody), url: nil)
    }

    func send(_ notifications: [PullRequestNotification]) async {
        guard isEnabled, !notifications.isEmpty else { return }
        await refreshAuthorization()
        guard isAuthorized else { return }
        for notification in notifications {
            guard isEnabled, !Task.isCancelled else { return }
            let pullRequest = notification.pullRequest
            try? await send(
                title: notification.queue.title,
                body: "\(pullRequest.author.login) — \(pullRequest.shortRepository) "
                    + "#\(pullRequest.number)\n\(pullRequest.title)",
                url: pullRequest.url
            )
        }
    }

    private func send(title: String, body: String, url: URL?) async throws {
        guard let center else { throw NotificationError.unavailable }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        if let url { content.userInfo = ["url": url.absoluteString] }

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil // inmediata
        )
        try await center.add(request)
    }
}

// MARK: - UNUserNotificationCenterDelegate

extension Notifier: UNUserNotificationCenterDelegate {
    /// Show banners while the app is active. Callbacks are `nonisolated` because the protocol is not main-actor annotated and its parameters are not Sendable; an `@MainActor` class cannot receive them directly.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    /// Clicking a notification opens the PR.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        // Extract the Sendable String before crossing to the main actor; `response` is not Sendable.
        let stored = response.notification.request.content.userInfo["url"] as? String
        guard let stored, let url = URL(string: stored) else { return }
        await MainActor.run { _ = NSWorkspace.shared.open(url) }
    }
}
