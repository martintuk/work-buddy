import SwiftUI

/// Configuración accesible desde el encabezado general.
struct ConfigurationView: View {
    let store: ReviewQueueStore

    private enum Field: Hashable {
        case organization
        case machineAccounts
    }

    @AppStorage("appearance.showEmptySections") private var showEmptySections = true
    @State private var selectedOrganizations: Set<String> = []
    @State private var availableOrganizations: [String] = []
    @State private var isLoadingOrganizations = false
    @State private var organizationsError: (any Error)?
    @State private var organizationsRequest = 0
    @State private var machineAccounts = ""
    @State private var configurationErrors: [Field: any Error] = [:]
    @FocusState private var focusedField: Field?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 8) {
                    Text(L10n.text(.settingsLanguage))
                        .font(.system(size: 12, weight: .semibold))
                    Spacer()
                    Picker(L10n.text(.settingsLanguage), selection: Binding(
                        get: { Localization.shared.language },
                        set: { Localization.shared.setLanguage($0) }
                    )) {
                        ForEach(AppLanguage.allCases, id: \.self) { language in
                            Text(language.nativeName).tag(language)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .accessibilityLabel(L10n.text(.settingsLanguage))
                }
                .controlSize(.small)

                HStack(spacing: 8) {
                    Text(L10n.text(.settingsEmptySections))
                        .font(.system(size: 12, weight: .semibold))
                    Spacer()
                    Toggle(L10n.text(.settingsEmptySections), isOn: $showEmptySections)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .help(L10n.text(.settingsEmptySectionsHelp))
                }
                .controlSize(.small)

                NotificationSettingsView(notifier: store.notifier)

                organizationsSelector

                VStack(alignment: .leading, spacing: 6) {
                    Text(L10n.text(.settingsMachineAccounts))
                        .font(.system(size: 12, weight: .semibold))
                    TextField(L10n.text(.settingsMachineAccountsPlaceholder), text: $machineAccounts)
                        .textFieldStyle(.roundedBorder)
                        .focused($focusedField, equals: .machineAccounts)
                        .onSubmit { saveConfiguration(field: .machineAccounts) }
                    configurationError(for: .machineAccounts)
                    Text(L10n.text(.settingsMachineAccountsHelp))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }

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
                Text(L10n.text(.settingsOrganizations))
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                RefreshButton(
                    isRefreshing: isLoadingOrganizations,
                    label: L10n.text(.settingsRefreshOrganizations)
                ) {
                    organizationsRequest += 1
                }
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
                                        Text(L10n.text(.settingsSavedOrganization))
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
                Text(L10n.text(.settingsNoOrganizations))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }

            if let organizationsError {
                Label(organizationsError.localizedDescription, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.red)
                Button(L10n.text(.commonRetry)) { organizationsRequest += 1 }
                    .controlSize(.small)
                    .disabled(isLoadingOrganizations)
            }
            configurationError(for: .organization)

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
            organizationsError = error
        }
    }

    @ViewBuilder
    private func configurationError(for field: Field) -> some View {
        if let error = configurationErrors[field] {
            Label(error.localizedDescription, systemImage: "exclamationmark.triangle.fill")
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
            configurationErrors[field] = error
        }
    }

}
