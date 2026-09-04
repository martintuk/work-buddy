import SwiftUI

struct NotificationSettingsView: View {
    let notifier: Notifier

    @State private var isWorking = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("Notificaciones")
                    .font(.system(size: 12, weight: .semibold))

                Spacer()

                if isWorking {
                    ProgressView().controlSize(.mini)
                }

                Button("Probar") {
                    perform { try await notifier.sendTest() }
                }
                .disabled(isWorking || !notifier.isAvailable)
                .help("Enviar una notificación de prueba")

                Toggle("Habilitar", isOn: Binding(
                    get: { notifier.isEnabled },
                    set: { enabled in
                        perform { try await notifier.setEnabled(enabled) }
                    }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .fixedSize()
                .disabled(isWorking || !notifier.isAvailable)
                .help("Activar o desactivar los envíos de notificaciones de work-buddy")
                .accessibilityLabel("Habilitar notificaciones de work-buddy")

            }
            .controlSize(.small)

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.red)
            }
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

}
