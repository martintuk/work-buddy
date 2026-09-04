import SwiftUI

struct NotificationSettingsView: View {
    let notifier: Notifier

    @State private var isWorking = false
    @State private var errorMessage: (any Error)?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(L10n.text(.notificationsTitle))
                    .font(.system(size: 12, weight: .semibold))

                Spacer()

                if isWorking {
                    ProgressView().controlSize(.mini)
                }

                Button(L10n.text(.notificationsTest)) {
                    perform { try await notifier.sendTest() }
                }
                .disabled(isWorking || !notifier.isAvailable)
                .help(L10n.text(.notificationsTestHelp))

                Toggle(L10n.text(.notificationsEnable), isOn: Binding(
                    get: { notifier.isEnabled },
                    set: { enabled in
                        perform { try await notifier.setEnabled(enabled) }
                    }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .fixedSize()
                .disabled(isWorking || !notifier.isAvailable)
                .help(L10n.text(.notificationsToggleHelp))
                .accessibilityLabel(L10n.text(.notificationsEnableAccessibility))

            }
            .controlSize(.small)

            if let errorMessage {
                Label(errorMessage.localizedDescription, systemImage: "exclamationmark.triangle.fill")
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
                errorMessage = error
            }
        }
    }

}
