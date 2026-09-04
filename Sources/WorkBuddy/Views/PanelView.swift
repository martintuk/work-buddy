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
    @State private var isPinned = false

    private enum Category: String, CaseIterable, Identifiable {
        case github = "GitHub"
        case jira = "Jira"

        var id: Self { self }
    }

    var body: some View {
        panel
        .frame(width: Self.preferredSize.width, height: Self.preferredSize.height)
        .environment(\.locale, Locale(identifier: Localization.shared.language.rawValue))
        .onChange(of: Localization.shared.language) { _, _ in onLanguageChange() }
    }

    private var panel: some View {
        VStack(spacing: 0) {
            header

            if showingConfiguration {
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

            Divider()
            footer
        }
        .frame(width: Self.preferredSize.width, height: Self.preferredSize.height)
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
            RefreshButton(isRefreshing: isRefreshing, label: L10n.text(.panelRefresh)) { refresh() }

            Button {
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
        if case .loading = store.state { return true }
        return jiraStore.isChecking
    }

    private func refresh() {
        store.refresh(force: true)
        jiraStore.refresh()
    }

    @ViewBuilder
    private var categoryContent: some View {
        switch selectedCategory {
        case .github:
            GitHubSectionView(store: store) { showingRepositories = true }
        case .jira:
            JiraSectionView(store: jiraStore)
        }
    }

    private var footer: some View {
        HStack {
            if selectedCategory == .github, let lastUpdated = store.lastUpdated {
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
