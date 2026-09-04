import SwiftUI

struct AgentCLISettingsView: View {
    @Bindable var store: AgentCLIStore

    var body: some View {
        // Group deja que el VStack de Configuración aplique el mismo espaciado a cada campo.
        Group {
            HStack {
                Text(L10n.text(.agentTerminal)).font(.system(size: 12, weight: .semibold))
                Spacer()
                Picker(L10n.text(.agentTerminal), selection: $store.terminal) {
                    ForEach(AgentTerminal.allCases.filter { $0 == .custom || store.installedTerminals.contains($0) || $0 == store.terminal }) { terminal in
                        Text(terminal.name).tag(terminal)
                    }
                }
                .labelsHidden()
                .fixedSize()
            }
            if store.terminal == .custom {
                TextField(L10n.text(.agentTerminalCommand), text: $store.customTerminalCommand)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel(L10n.text(.agentTerminalCommand))
                    .help(L10n.text(.agentTerminalCommandHelp))
            }
            HStack {
                Text(L10n.text(.agentTitle)).font(.system(size: 12, weight: .semibold))
                Spacer()
                Picker(L10n.text(.agentTitle), selection: $store.agent) {
                    ForEach(AgentCLI.allCases) { agent in
                        Text(agent.name).tag(agent)
                    }
                }
                .labelsHidden()
                .fixedSize()
            }
            if store.agent == .custom {
                TextField(L10n.text(.agentCommand), text: $store.customCommand)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel(L10n.text(.agentCommand))
                    .help(L10n.text(.agentCommand))
            }
        }
        .controlSize(.small)
        .onAppear { store.refreshTerminals() }
    }
}
