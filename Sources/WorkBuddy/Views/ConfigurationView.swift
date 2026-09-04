import SwiftUI

/// Configuración accesible desde el encabezado general.
struct ConfigurationView: View {
    let store: ReviewQueueStore

    private enum Field: Hashable {
        case organization
        case machineAccounts
    }

    @State private var selectedOrganizations: Set<String> = []
    @State private var availableOrganizations: [String] = []
    @State private var isLoadingOrganizations = false
    @State private var organizationsError: String?
    @State private var organizationsRequest = 0
    @State private var machineAccounts = ""
    @State private var configurationErrors: [Field: String] = [:]
    @FocusState private var focusedField: Field?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                organizationsSelector

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

                Text("Las organizaciones se guardan al seleccionarlas. Las cuentas, al salir del campo o presionar Enter.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            .padding(16)
        }
        .onAppear {
            selectedOrganizations = store.configuration.organizations
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

    private var listedOrganizations: [String] {
        Set(availableOrganizations).union(selectedOrganizations).sorted()
    }

    private var organizationsSelector: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Tus organizaciones de GitHub")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Button {
                    organizationsRequest += 1
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Actualizar lista")
                .accessibilityLabel("Actualizar lista de organizaciones")
                .disabled(isLoadingOrganizations)
            }

            if isLoadingOrganizations {
                ProgressView("Leyendo organizaciones de GitHub…")
                    .controlSize(.small)
                    .font(.system(size: 11))
            }

            if !listedOrganizations.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(listedOrganizations, id: \.self) { organization in
                            Toggle(isOn: Binding(
                                get: { selectedOrganizations.contains(organization) },
                                set: { selected in
                                    if selected {
                                        selectedOrganizations.insert(organization)
                                    } else {
                                        selectedOrganizations.remove(organization)
                                    }
                                    saveConfiguration(field: .organization)
                                }
                            )) {
                                HStack {
                                    Text(organization)
                                    if !availableOrganizations.contains(organization) {
                                        Text("Guardada · no disponible en la lista")
                                            .font(.system(size: 9))
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                            .toggleStyle(.checkbox)
                            .font(.system(size: 11))
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                }
                .frame(height: min(CGFloat(listedOrganizations.count) * 28 + 10, 170))
                .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
            } else if !isLoadingOrganizations && organizationsError == nil {
                Text("GitHub no devolvió organizaciones para esta sesión de gh.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }

            if let organizationsError {
                Label(organizationsError, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.red)
                Button("Reintentar") { organizationsRequest += 1 }
                    .controlSize(.small)
                    .disabled(isLoadingOrganizations)
            }
            configurationError(for: .organization)

            Text("Elegí una o varias. Sin selección, se buscan PRs en todo lo accesible con gh.")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
        .task(id: organizationsRequest) { await loadOrganizations() }
    }

    private func loadOrganizations() async {
        isLoadingOrganizations = true
        organizationsError = nil
        defer { isLoadingOrganizations = false }
        do {
            let organizations = try await GitHubOrganizations.fetch()
            try Task.checkCancellation()
            availableOrganizations = organizations
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            organizationsError = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
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
                organizations: field == .organization
                    ? selectedOrganizations : store.configuration.organizations,
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
