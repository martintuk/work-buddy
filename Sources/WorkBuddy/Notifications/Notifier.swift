import AppKit
import Observation
import UserNotifications

/// Avisa cuando aparece un PR nuevo que espera tu review.
///
/// Sólo notifica PRs de personas en la cola "Para revisar": los de bots son el
/// 89% del volumen y notificarlos convertiría esto en ruido.
@MainActor
@Observable
final class Notifier: NSObject {
    /// Pasado este número mandamos un solo resumen. Si entran diez PRs juntos,
    /// diez banners seguidos son peores que ninguno.
    private static let maxIndividual = 3

    private static let seenKey = "notifier.seenPullRequestIDs"
    private static let seededKey = "notifier.hasSeededBaseline"

    private let defaults = UserDefaults.standard

    /// `nil` cuando corremos sin bundle (por ejemplo el binario pelado desde
    /// `.build/`): pedirle el centro de notificaciones a un proceso sin bundle
    /// identifier es un crash, no un error recuperable.
    private let center: UNUserNotificationCenter?

    private(set) var authorizationStatus: UNAuthorizationStatus?

    var isAvailable: Bool { center != nil }
    var isAuthorized: Bool {
        authorizationStatus == .authorized || authorizationStatus == .provisional
    }

    enum NotificationError: LocalizedError {
        case unavailable
        case permissionRequired

        var errorDescription: String? {
            switch self {
            case .unavailable: "Las notificaciones requieren ejecutar la app desde su bundle."
            case .permissionRequired: "Habilitá las notificaciones de work-buddy en los ajustes de macOS."
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
        _ = try await center.requestAuthorization(options: [.alert, .sound])
        await refreshAuthorization()
        guard isAuthorized else { throw NotificationError.permissionRequired }
    }

    func sendTest() async throws {
        await refreshAuthorization()
        guard isAvailable else { throw NotificationError.unavailable }
        guard isAuthorized else { throw NotificationError.permissionRequired }
        try await send(title: "work-buddy", body: "Notificación de prueba", url: nil)
    }

    /// Cambiar el alcance no debe notificar de golpe todo el backlog del nuevo
    /// entorno. La próxima carga vuelve a sembrar una línea de base silenciosa.
    func resetBaseline() {
        defaults.removeObject(forKey: Self.seenKey)
        defaults.removeObject(forKey: Self.seededKey)
    }

    /// Compara la cola nueva con la anterior y notifica sólo las diferencias.
    func process(_ pullRequests: [PullRequest]) async {
        let relevant = pullRequests.awaitingYourReview
        let currentIDs = Set(relevant.map(\.id))

        // Primera corrida: guardamos el backlog como línea de base sin notificar.
        // Si no, instalar la app te dispararía una notificación por PR pendiente.
        guard defaults.bool(forKey: Self.seededKey) else {
            persist(currentIDs)
            defaults.set(true, forKey: Self.seededKey)
            return
        }

        let seen = Set(defaults.stringArray(forKey: Self.seenKey) ?? [])
        let new = relevant.filter { !seen.contains($0.id) }

        // Guardamos el set actual, no la unión: si revisás un PR y después te lo
        // vuelven a pedir, queremos que avise de nuevo.
        persist(currentIDs)

        await refreshAuthorization()
        guard isAuthorized, !new.isEmpty else { return }
        if new.count > Self.maxIndividual {
            try? await send(
                title: "\(new.count) PRs nuevos para revisar",
                body: new.map(\.author.login).uniqued().joined(separator: ", "),
                url: nil
            )
        } else {
            for pullRequest in new {
                try? await send(
                    title: "Nuevo PR para revisar",
                    body: "\(pullRequest.author.login) — \(pullRequest.shortRepository) "
                        + "#\(pullRequest.number)\n\(pullRequest.title)",
                    url: pullRequest.url
                )
            }
        }
    }

    private func persist(_ ids: Set<String>) {
        defaults.set(Array(ids), forKey: Self.seenKey)
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

private extension Sequence where Element: Hashable {
    /// Preserva el orden, a diferencia de `Set`.
    func uniqued() -> [Element] {
        var seen: Set<Element> = []
        return filter { seen.insert($0).inserted }
    }
}
