import AppKit
import Observation
import UserNotifications

/// Gestiona el permiso de macOS y entrega notificaciones individuales.
@MainActor
@Observable
final class Notifier: NSObject {
    private static let enabledKey = "notifier.isEnabled"

    private let defaults = UserDefaults.standard

    /// `nil` cuando corremos sin bundle (por ejemplo el binario pelado desde
    /// `.build/`): pedirle el centro de notificaciones a un proceso sin bundle
    /// identifier es un crash, no un error recuperable.
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
        // La prueba es explícita y no modifica la preferencia de envíos automáticos.
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
    /// Sin esto el banner no aparece si la app está activa.
    ///
    /// Los callbacks van `nonisolated` porque el protocolo no está anotado para
    /// el main actor y sus parámetros no son Sendable: no se pueden recibir
    /// directamente en una clase `@MainActor`.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    /// Click en la notificación abre el PR.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        // Sacamos el String antes de cruzar al main actor: es Sendable, el
        // `response` no.
        let stored = response.notification.request.content.userInfo["url"] as? String
        guard let stored, let url = URL(string: stored) else { return }
        await MainActor.run { _ = NSWorkspace.shared.open(url) }
    }
}
