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
    @State private var activityExpanded = false
    @State private var activityFocus: ActivityLog.Focus?
    @State private var revealPullRequestID: String?
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
        .onChange(of: Localization.shared.language) { _, _ in onLanguageChange() }
    }

    private var panel: some View {
        VStack(spacing: 0) {
            header

            if showingActivity {
                ActivityView(activity: store.activity, isExpanded: $activityExpanded,
                             close: { showingActivity = false },
                             canVerify: store.canVerify, verify: { entry in Task { await store.verifyActivity(entry.id) } },
                             canRetry: store.canRetry, retry: { store.retryActivity($0.id) },
                             focus: activityFocus,
                             clearFocus: { activityFocus = nil },
                             canShowInList: { entry in
                                 entry.pullRequest.map { store.visibleSectionID(for: $0.id) != nil } ?? false
                             }, showInList: { entry in
                                 selectedCategory = .github
                                 showingConfiguration = false
                                 showingRepositories = false
                                 showingActivity = false
                                 revealPullRequestID = entry.pullRequest?.id
                             })
                    .frame(maxHeight: activityExpanded ? .infinity : 220)
                if !activityExpanded { Divider() }
            }

            if showingActivity && activityExpanded {
                // El historial ocupa el mismo panel, sin otra ventana flotante.
            } else if showingConfiguration {
                navigationHeader(title: L10n.text(.settingsTitle)) { showingConfiguration = false }
                Divider()
                ConfigurationView(store: store)
            } else if showingRepositories {
                navigationHeader(title: L10n.text(.repositoriesTitle)) { showingRepositories = false }
                Divider()
                RepositoryFilterView(store: store, parentWindow: repositoryPickerWindow)
            } else {
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
                categoryContent
            }

            if showingGitHub || store.autopilot.isActive || store.batch.isRunning {
                PullRequestExecutionControls(store: store, compact: showingActivity || !showingGitHub) { focus in
                    activityFocus = focus
                    showingActivity = true
                }
            }
            Divider()
            footer
        }
        .frame(width: Self.preferredSize.width, height: Self.preferredSize.height)
    }

    private var showingGitHub: Bool {
        selectedCategory == .github && !showingConfiguration && !showingRepositories
            && !(showingActivity && activityExpanded)
    }

    private func navigationHeader(title: String, back: @escaping () -> Void) -> some View {
        HStack {
            Button(action: back) {
                Image(systemName: "chevron.left")
            }
            .buttonStyle(.borderless)
            .help(L10n.text(.commonBack))
            .accessibilityLabel(L10n.text(.commonBack))
            Spacer()
        }
        .overlay {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .accessibilityAddTraits(.isHeader)
        }
        .frame(height: 24)
        .padding(.horizontal, 14)
        .padding(.bottom, 10)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Text("Work Buddy")
                .font(.system(size: 13, weight: .semibold))
            Spacer()

            Button {
                activityFocus = nil
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
        store.isRefreshing || jiraStore.isChecking
    }

    @ViewBuilder
    private var categoryContent: some View {
        switch selectedCategory {
        case .github:
            GitHubSectionView(store: store, showActivity: { focus in
                activityFocus = focus
                showingActivity = true
            }, showsExecutionControls: false, revealPullRequestID: $revealPullRequestID) {
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
            } else if selectedCategory == .github, let lastUpdated = store.lastUpdated {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(LastUpdatedText.format(lastUpdated, relativeTo: context.date))
                }
            } else if selectedCategory == .jira, let lastUpdated = jiraStore.lastUpdated {
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
