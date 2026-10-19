import AppKit
import SwiftUI

/// Contenedor de las categorías del panel de la barra de menú.
struct PanelView: View {
    static let preferredSize = NSSize(width: 420, height: 560)

    let store: ReviewQueueStore
    let jiraStore: JiraStore
    var onLanguageChange: () -> Void = {}
    var onPinChange: (Bool) -> Void = { _ in }
    var repositoryPickerWindow: () -> NSWindow? = { nil }

    @State private var selectedCategory: Category = .github
    @State private var showingConfiguration = false
    @State private var showingRepositories = false
    @State private var showingActivity = false
    @State private var isPinned = false

    private enum Category: String, CaseIterable, Identifiable {
        case github = "GitHub"
        case jira = "Jira"

        var id: Self { self }
    }

    var body: some View {
        panel
        .frame(width: Self.preferredSize.width, height: Self.preferredSize.height)
        // La misma base opaca que los encabezados fijos, también en márgenes y pie.
        .background(Color(nsColor: .windowBackgroundColor))
        .environment(\.locale, Locale(identifier: Localization.shared.language.rawValue))
        .onChange(of: jiraStore.isEnabled) { _, enabled in
            if !enabled { selectedCategory = .github }
        }
        .onChange(of: Localization.shared.language) { _, _ in onLanguageChange() }
    }

    private var panel: some View {
        VStack(spacing: 0) {
            header

            if showingActivity {
                ActivityView(activity: store.activity) { showingActivity = false }
                    .frame(maxHeight: .infinity)
            } else if showingConfiguration {
                SubsectionHeader(title: L10n.text(.settingsTitle)) { showingConfiguration = false }
                ConfigurationView(store: store, jiraStore: jiraStore)
            } else if showingRepositories {
                SubsectionHeader(title: L10n.text(.repositoriesTitle)) { showingRepositories = false }
                RepositoryFilterView(store: store, parentWindow: repositoryPickerWindow)
            } else {
                if jiraStore.isEnabled {
                    Picker(L10n.text(.panelCategory), selection: $selectedCategory) {
                        ForEach(Category.allCases) { category in
                            Text(category.rawValue).tag(category)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .padding(.horizontal, 14)
                    .padding(.bottom, 10)

                    Divider()
                }
                categoryContent
            }

            if showingGitHub || store.autopilot.isActive || store.batch.isRunning {
                PullRequestExecutionControls(store: store, compact: showingActivity || !showingGitHub)
            }
            Divider()
            footer
        }
        .frame(width: Self.preferredSize.width, height: Self.preferredSize.height)
    }

    private var effectiveCategory: Category { jiraStore.isEnabled ? selectedCategory : .github }

    private var showingGitHub: Bool {
        effectiveCategory == .github && !showingConfiguration && !showingRepositories
            && !showingActivity
    }

    private var header: some View {
        HStack(spacing: 12) {
            Text("Work Buddy")
                .font(.system(size: 13, weight: .semibold))
            Spacer()

            Button {
                showingActivity.toggle()
                if showingActivity {
                    showingConfiguration = false
                    showingRepositories = false
                }
            } label: {
                Image(systemName: "clock.arrow.circlepath")
                    .foregroundStyle(showingActivity ? Color.accentColor : Color.secondary)
                    .overlay(alignment: .topTrailing) {
                        if !store.activity.unreadIDs.isEmpty {
                            Circle().fill(store.activity.hasUnreadErrors ? Color.red : Color.accentColor)
                                .frame(width: 6, height: 6).offset(x: 3, y: -2)
                        }
                    }
            }
            .buttonStyle(.borderless)
            .help(L10n.text(showingActivity ? .activityClose : .activityTitle))
            .accessibilityLabel(L10n.text(.activityTitle))
            .accessibilityValue(L10n.text(.activityUnread, String(store.activity.unreadIDs.count)))

            Button {
                showingActivity = false
                showingConfiguration.toggle()
            } label: {
                Image(systemName: "gearshape")
                    .foregroundStyle(showingConfiguration ? Color.accentColor : Color.secondary)
            }
            .buttonStyle(.borderless)
            .help(showingConfiguration ? L10n.text(.settingsClose) : L10n.text(.settingsTitle))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var isRefreshing: Bool {
        store.isRefreshing || (jiraStore.isEnabled && jiraStore.isChecking)
    }

    @ViewBuilder
    private var categoryContent: some View {
        switch effectiveCategory {
        case .github:
            GitHubSectionView(store: store, showsExecutionControls: false) {
                showingActivity = false
                showingRepositories = true
            }
        case .jira:
            JiraSectionView(store: jiraStore, activity: store.activity)
        }
    }

    private var footer: some View {
        HStack {
            if isRefreshing {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.mini)
                        .frame(width: 12, height: 12)
                    Text(L10n.text(.commonRefreshing))
                }
                .accessibilityElement(children: .combine)
            } else if effectiveCategory == .github, let lastUpdated = store.lastUpdated {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(LastUpdatedText.format(lastUpdated, relativeTo: context.date))
                }
            } else if effectiveCategory == .jira, let lastUpdated = jiraStore.lastUpdated {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(LastUpdatedText.format(lastUpdated, relativeTo: context.date))
                }
            } else {
                Text("v\(Self.version)")
            }
            Spacer()
            Button {
                isPinned.toggle()
                onPinChange(isPinned)
            } label: {
                Image(systemName: isPinned ? "pin.fill" : "pin")
                    .font(.system(size: 12))
                    .rotationEffect(.degrees(45))
                    .foregroundStyle(isPinned ? Color.accentColor : Color.secondary)
            }
            .buttonStyle(.borderless)
            .help(L10n.text(isPinned ? .panelUnpin : .panelPin))
            .accessibilityLabel(L10n.text(isPinned ? .panelUnpin : .panelPin))
            .accessibilityValue(L10n.text(isPinned ? .commonEnabled : .commonDisabled))
        }
        .font(.system(size: 10))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }
}
