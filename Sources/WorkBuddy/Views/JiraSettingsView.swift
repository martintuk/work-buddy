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
                Text(L10n.text(.settingsJiraExperimental))
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Toggle(L10n.text(.settingsJiraExperimental), isOn: Binding(
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
                .accessibilityLabel(L10n.text(.settingsJiraExperimental))
            }

            if store.isEnabled {
                HStack(spacing: 8) {
                    Text(store.siteURL?.host ?? L10n.text(.settingsJiraAccount))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(L10n.text(.settingsJiraAccountHelp))
                    Spacer()
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(JiraSectionView.loginCommand, forType: .string)
                        copied = true
                    } label: {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    }
                    .help(L10n.text(copied ? .jiraCommandCopied : .settingsJiraCopyLogin))
                    .accessibilityLabel(L10n.text(.settingsJiraCopyLogin))
                    RefreshButton(isRefreshing: store.isChecking, label: L10n.text(.jiraCheckAgain)) {
                        store.refresh()
                    }
                }
                .font(.system(size: 11))

                queryFields(title: .settingsJiraPrimary, name: $draft.primaryName,
                            query: $draft.primaryJQL, placeholder: .jiraAssignedToMe)
                queryFields(title: .settingsJiraRecent, name: $draft.recentName,
                            query: $draft.recentJQL, placeholder: .jiraRecentlyCreated)

                HStack {
                    Button {
                        draft = JiraConfiguration()
                        draft.isEnabled = store.isEnabled
                        error = nil
                    } label: { Image(systemName: "arrow.counterclockwise") }
                        .help(L10n.text(.settingsJiraReset))
                        .accessibilityLabel(L10n.text(.settingsJiraReset))
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

    private func queryFields(title: L10n.Key, name: Binding<String>, query: Binding<String>,
                             placeholder: L10n.Key) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(L10n.text(title)).font(.system(size: 11, weight: .medium))
            TextField(L10n.text(placeholder), text: name)
                .accessibilityLabel(L10n.text(.settingsJiraQueueName))
            TextField("JQL", text: query, axis: .vertical)
                .lineLimit(2...4)
                .font(.system(size: 11, design: .monospaced))
                .accessibilityLabel(L10n.text(.settingsJiraQuery, L10n.text(title)))
                .help(L10n.text(.settingsJiraQueryHelp))
        }
        .textFieldStyle(.roundedBorder)
    }
}
