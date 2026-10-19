import SwiftUI

/// La pantalla general conserva sólo preferencias compartidas y acceso a cada integración.
struct ConfigurationView: View {
    let store: ReviewQueueStore
    let jiraStore: JiraStore
    var onBack: () -> Void = {}

    private enum Destination { case github, jira }
    @State private var destination: Destination?
    @AppStorage("appearance.showEmptySections") private var showEmptySections = true

    var body: some View {
        VStack(spacing: 0) {
            SubsectionHeader(title: title) {
                if destination != nil { destination = nil }
                else { onBack() }
            }
            switch destination {
            case .github:
                GitHubSettingsView(store: store)
            case .jira:
                ScrollView {
                    JiraSettingsView(store: jiraStore).padding(16)
                }
            case nil:
                generalSettings
            }
        }
    }

    private var title: String {
        switch destination {
        case .github: "GitHub"
        case .jira: "Jira"
        case nil: L10n.text(.settingsTitle)
        }
    }

    private var generalSettings: some View {
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

                VStack(spacing: 0) {
                    navigationRow("GitHub", destination: .github)
                    Divider()
                    navigationRow(L10n.text(.settingsJiraExperimental), destination: .jira)
                }
                .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
            }
            .padding(16)
        }
    }

    private func navigationRow(_ title: String, destination target: Destination) -> some View {
        Button { destination = target } label: {
            HStack {
                Text(title).font(.system(size: 12, weight: .medium))
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }
}
