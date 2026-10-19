import AppKit
import SwiftUI

struct JiraSettingsView: View {
    let store: JiraStore
    @State private var draft = JiraConfiguration()
    @State private var error: Error?
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(L10n.text(.settingsJiraEnable))
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Toggle(L10n.text(.settingsJiraEnable), isOn: Binding(
                    get: { store.isEnabled },
                    set: { enabled in
                        do {
                            try store.setEnabled(enabled)
                            draft.isEnabled = enabled
                            error = nil
                        } catch { self.error = error }
                    }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .accessibilityLabel(L10n.text(.settingsJiraEnable))
            }

            if store.isEnabled {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 8) {
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(JiraSectionView.loginCommand, forType: .string)
                            copied = true
                        } label: {
                            Label(L10n.text(copied ? .jiraCommandCopied : .settingsJiraCopyLogin),
                                  systemImage: copied ? "checkmark" : "doc.on.doc")
                        }
                        .help(L10n.text(.settingsJiraAccountHelp))
                        Spacer(minLength: 0)
                        RefreshButton(isRefreshing: store.isChecking, label: L10n.text(.settingsJiraVerifyConnection)) {
                            store.refresh()
                        }
                    }
                    Text(L10n.text(.settingsJiraAccountHelp))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    if let host = store.siteURL?.host {
                        Text(L10n.text(.settingsJiraConnectedSite, host))
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }

                Divider()
                Text(L10n.text(.settingsJiraListsHelp))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                queryFields(title: store.configuration.primaryTitle, name: $draft.primaryName,
                            query: $draft.primaryJQL, placeholder: .jiraAssignedToMe)
                queryFields(title: L10n.text(.settingsJiraListLimit, store.configuration.recentTitle),
                            name: $draft.recentName, query: $draft.recentJQL, placeholder: .jiraRecentlyCreated)

                HStack {
                    Button(L10n.text(.settingsJiraReset)) {
                        draft = JiraConfiguration()
                        draft.isEnabled = store.isEnabled
                        error = nil
                    }
                    .help(L10n.text(.settingsJiraResetHelp))
                    Spacer()
                    Button(L10n.text(.settingsJiraSave)) {
                        do {
                            try store.configure(draft)
                            draft = store.configuration
                            error = nil
                        } catch { self.error = error }
                    }
                    .disabled(draft == store.configuration)
                }
            }
            if let error {
                Text(error.localizedDescription)
                    .font(.system(size: 10))
                    .foregroundStyle(.red)
            }
        }
        .controlSize(.small)
        .onAppear { draft = store.configuration }
    }

    private func queryFields(title: String, name: Binding<String>, query: Binding<String>,
                             placeholder: L10n.Key) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 11, weight: .semibold))
            Text(L10n.text(.settingsJiraQueueName))
                .font(.system(size: 10)).foregroundStyle(.secondary)
            TextField(L10n.text(placeholder), text: name)
                .accessibilityLabel(L10n.text(.settingsJiraQueueName))
            Text(L10n.text(.settingsJiraQueryLabel))
                .font(.system(size: 10)).foregroundStyle(.secondary)
            TextField("JQL", text: query, axis: .vertical)
                .lineLimit(2...4)
                .font(.system(size: 11, design: .monospaced))
                .accessibilityLabel(L10n.text(.settingsJiraQuery, title))
                .help(L10n.text(.settingsJiraQueryHelp))
        }
        .textFieldStyle(.roundedBorder)
    }
}
