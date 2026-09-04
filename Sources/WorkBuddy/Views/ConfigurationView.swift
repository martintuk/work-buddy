import SwiftUI

/// Configuración accesible desde el encabezado general.
struct ConfigurationView: View {
    let store: ReviewQueueStore
    let onSave: () -> Void

    @State private var organization = ""
    @State private var machineAccounts = ""
    @State private var configurationError: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Organización de GitHub")
                        .font(.system(size: 12, weight: .semibold))
                    TextField("mi-organizacion", text: $organization)
                        .textFieldStyle(.roundedBorder)
                    Text("Opcional. Si queda vacía, se buscan PRs en todas las organizaciones "
                        + "a las que accede la sesión de gh.")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Cuentas de automatización")
                        .font(.system(size: 12, weight: .semibold))
                    TextField("ci-bot, release-bot", text: $machineAccounts)
                        .textFieldStyle(.roundedBorder)
                    Text("Logins que GitHub identifica como User aunque sean cuentas de máquina. "
                        + "Separalos con comas o espacios.")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }

                Text("Estos campos guardan identificadores, no tokens. La autenticación sigue "
                    + "a cargo de gh.")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)

                if let configurationError {
                    Label(configurationError, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.red)
                }

                HStack {
                    Spacer()
                    Button("Guardar y actualizar") {
                        saveConfiguration()
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding(16)
        }
        .onAppear {
            organization = store.configuration.organizationText
            machineAccounts = store.configuration.machineAccountsText
        }
    }

    private func saveConfiguration() {
        do {
            try store.updateConfiguration(
                organization: organization,
                machineAccounts: machineAccounts
            )
            onSave()
            configurationError = nil
        } catch {
            configurationError = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
        }
    }

}
