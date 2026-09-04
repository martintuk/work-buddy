import SwiftUI

/// Configuración accesible desde el encabezado general.
struct ConfigurationView: View {
    let store: ReviewQueueStore

    private enum Field: Hashable {
        case organization
        case machineAccounts
    }

    @State private var organization = ""
    @State private var machineAccounts = ""
    @State private var configurationErrors: [Field: String] = [:]
    @FocusState private var focusedField: Field?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Organización de GitHub")
                        .font(.system(size: 12, weight: .semibold))
                    TextField("mi-organizacion", text: $organization)
                        .textFieldStyle(.roundedBorder)
                        .focused($focusedField, equals: .organization)
                        .onSubmit { saveConfiguration(field: .organization) }
                    configurationError(for: .organization)
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
                        .focused($focusedField, equals: .machineAccounts)
                        .onSubmit { saveConfiguration(field: .machineAccounts) }
                    configurationError(for: .machineAccounts)
                    Text("Logins que GitHub identifica como User aunque sean cuentas de máquina. "
                        + "Separalos con comas o espacios.")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }

                Text("Estos campos guardan identificadores, no tokens. La autenticación sigue "
                    + "a cargo de gh.")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)

                Text("Los campos se guardan al salir del campo o presionar Enter.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            .padding(16)
        }
        .onAppear {
            organization = store.configuration.organizationText
            machineAccounts = store.configuration.machineAccountsText
        }
        .onChange(of: focusedField) { previousField, _ in
            if let previousField {
                saveConfiguration(field: previousField)
            }
        }
        .onDisappear {
            saveConfiguration(field: .organization)
            saveConfiguration(field: .machineAccounts)
        }
    }

    @ViewBuilder
    private func configurationError(for field: Field) -> some View {
        if let error = configurationErrors[field] {
            Label(error, systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 10))
                .foregroundStyle(.red)
        }
    }

    private func saveConfiguration(field: Field) {
        do {
            // Cada campo se valida y aplica independientemente del otro borrador.
            try store.updateConfiguration(
                organization: field == .organization
                    ? organization : store.configuration.organizationText,
                machineAccounts: field == .machineAccounts
                    ? machineAccounts : store.configuration.machineAccountsText
            )
            configurationErrors[field] = nil
        } catch {
            configurationErrors[field] = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
        }
    }

}
