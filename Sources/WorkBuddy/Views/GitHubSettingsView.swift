import SwiftUI

/// Preferencias de GitHub; consulta organizaciones y equipos sólo al abrir esta sección.
struct GitHubSettingsView: View {
    let store: ReviewQueueStore

    private enum Field: Hashable {
        case organization
        case machineAccounts
        case teams
    }

    @AppStorage("actions.autoConfirm") private var autoConfirmActions = false
    @State private var selectedOrganizations: Set<String> = []
    @State private var availableOrganizations: [String] = []
    @State private var isLoadingOrganizations = false
    @State private var organizationsError: (any Error)?
    @State private var organizationsRequest = 0
    @State private var teamDependabotEnabled = false
    @State private var selectedTeams: Set<String> = []
    @State private var availableTeams: [String] = []
    @State private var isLoadingTeams = false
    @State private var teamsError: (any Error)?
    @State private var teamsRequest = 0
    @State private var machineAccounts = ""
    @State private var configurationErrors: [Field: any Error] = [:]
    @FocusState private var focusedField: Field?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 8) {
                    Text(L10n.text(.settingsAutoConfirmActions))
                        .font(.system(size: 12, weight: .semibold))
                    Spacer()
                    Toggle(L10n.text(.settingsAutoConfirmActions), isOn: $autoConfirmActions)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .help(L10n.text(.settingsAutoConfirmActionsHelp))
                        .accessibilityLabel(L10n.text(.settingsAutoConfirmActions))
                }
                .controlSize(.small)

                NotificationSettingsView(notifier: store.notifier)

                HStack(spacing: 8) {
                    Text(L10n.text(.settingsEditor))
                        .font(.system(size: 12, weight: .semibold))
                    Spacer()
                    EditorPicker(store: store.editor)
                }
                .controlSize(.small)

                AgentCLISettingsView(store: store.agentCLI)

                organizationsSelector

                teamDependabotSelector

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
            teamDependabotEnabled = store.configuration.teamDependabotEnabled
            selectedTeams = store.configuration.dependabotTeams
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
        Set(availableOrganizations).union(selectedOrganizations).sorted { lhs, rhs in
            let lhsSelected = selectedOrganizations.contains(lhs)
            let rhsSelected = selectedOrganizations.contains(rhs)
            return lhsSelected == rhsSelected ? lhs < rhs : lhsSelected
        }
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

    private var listedTeams: [String] {
        Set(availableTeams).union(selectedTeams).filter {
            selectedOrganizations.isEmpty || selectedOrganizations.contains(String($0.split(separator: "/")[0]))
        }.sorted { lhs, rhs in
            let lhsSelected = selectedTeams.contains(lhs)
            let rhsSelected = selectedTeams.contains(rhs)
            return lhsSelected == rhsSelected ? lhs < rhs : lhsSelected
        }
    }

    private var teamDependabotSelector: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(L10n.text(.settingsTeamDependabot))
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Toggle(L10n.text(.settingsTeamDependabot), isOn: Binding(
                    get: { teamDependabotEnabled },
                    set: { teamDependabotEnabled = $0; saveConfiguration(field: .teams) }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
            }
            Text(L10n.text(.settingsTeamDependabotHelp))
                .font(.system(size: 10))
                .foregroundStyle(.secondary)

            if teamDependabotEnabled {
                HStack(alignment: .top, spacing: 8) {
                    if !listedTeams.isEmpty {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 10) {
                                ForEach(listedTeams, id: \.self) { team in
                                    Toggle(team, isOn: Binding(
                                        get: { selectedTeams.contains(team) },
                                        set: { selected in
                                            if selected { selectedTeams.insert(team) }
                                            else { selectedTeams.remove(team) }
                                            saveConfiguration(field: .teams)
                                        }
                                    ))
                                    .toggleStyle(.checkbox)
                                    .font(.system(size: 11))
                                    .help(team)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                        }
                        .frame(height: min(CGFloat(listedTeams.count) * 28 + 10, 170))
                        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                    } else if !isLoadingTeams && teamsError == nil {
                        Text(L10n.text(.settingsNoTeams))
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    RefreshButton(
                        isRefreshing: isLoadingTeams || store.isLoadingTeamDependabot,
                        label: L10n.text(.settingsRefreshTeams)
                    ) {
                        teamsRequest += 1
                        store.retryTeamDependabot()
                    }
                }
                .task(id: teamsRequest) { await loadTeams() }
                if let teamsError {
                    Label(teamsError.localizedDescription, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.red)
                    Button(L10n.text(.commonRetry)) { teamsRequest += 1 }
                        .controlSize(.small)
                        .disabled(isLoadingTeams)
                }
                if let failure = store.teamDependabotFailure {
                    Label(failure.text, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.red)
                    Button(L10n.text(.commonRetry)) { store.retryTeamDependabot() }
                        .controlSize(.small)
                        .disabled(store.isLoadingTeamDependabot)
                }
            }
            configurationError(for: .teams)
        }
    }

    private func loadTeams() async {
        isLoadingTeams = true
        teamsError = nil
        defer { isLoadingTeams = false }
        do {
            let teams = try await GitHubTeams.fetch()
            try Task.checkCancellation()
            availableTeams = teams
        } catch {
            guard !Task.isCancelled else { return }
            teamsError = error
        }
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
                    ? machineAccounts : store.configuration.machineAccountsText,
                teamDependabotEnabled: field == .teams
                    ? teamDependabotEnabled : store.configuration.teamDependabotEnabled,
                dependabotTeams: field == .teams
                    ? selectedTeams : store.configuration.dependabotTeams
            )
            configurationErrors[field] = nil
        } catch {
            configurationErrors[field] = error
        }
    }

}
