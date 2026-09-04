import AppKit
import SwiftUI

struct NotificationSettingsView: View {
    let notifier: Notifier

    @State private var isWorking = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Notificaciones del sistema")
                .font(.system(size: 12, weight: .semibold))

            HStack(spacing: 8) {
                Button(notifier.isAuthorized ? "Habilitadas" : "Habilitar") {
                    if notifier.authorizationStatus == .denied {
                        openSettings()
                    } else {
                        perform { try await notifier.requestAuthorization() }
                    }
                }
                .disabled(isWorking || !notifier.isAvailable || notifier.isAuthorized)

                Button("Probar") {
                    perform { try await notifier.sendTest() }
                }
                .disabled(isWorking || !notifier.isAuthorized)
                .help("Enviar una notificación de prueba")

                Spacer()

                if isWorking {
                    ProgressView().controlSize(.mini)
                }

                Button(action: openSettings) {
                    Image(systemName: "gearshape")
                }
                .buttonStyle(.borderless)
                .help("Abrir ajustes de notificaciones de macOS")
                .accessibilityLabel("Abrir ajustes de notificaciones de macOS")
            }
            .controlSize(.small)

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.red)
            }
        }
        .task { await notifier.refreshAuthorization() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await notifier.refreshAuthorization() }
        }
    }

    private func perform(_ action: @escaping @MainActor () async throws -> Void) {
        isWorking = true
        errorMessage = nil
        Task { @MainActor in
            defer { isWorking = false }
            do {
                try await action()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func openSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.notifications"),
              NSWorkspace.shared.open(url) else {
            errorMessage = "No se pudieron abrir los ajustes de notificaciones de macOS."
            return
        }
        errorMessage = nil
    }
}
