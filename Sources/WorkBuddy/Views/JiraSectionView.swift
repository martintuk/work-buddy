import AppKit
import SwiftUI

struct JiraSectionView: View {
    static let loginCommand = "acli jira auth login"

    let store: JiraStore

    @AppStorage("appearance.showEmptySections") private var showEmptySections = true
    @State private var copiedLoginCommand = false
    @AppStorage("jira.shrExpanded") private var isSHRExpanded = true
    @AppStorage("jira.recentlyCreatedExpanded") private var isRecentlyCreatedExpanded = true

    var body: some View {
        Group {
            switch store.state {
            case .idle, .checking:
                ProgressView(L10n.text(.jiraLoading))
                    .controlSize(.small)
            case .signedOut:
                signedOut
            case .loaded:
                queue
            case .unavailable:
                ContentUnavailableView {
                    Label(L10n.text(.jiraMissingCLI), systemImage: "terminal")
                } description: {
                    Text(L10n.text(.jiraInstallCLI))
                } actions: {
                    retryButton
                }
            case .failed(let message):
                ContentUnavailableView {
                    Label(L10n.text(.jiraLoadFailed), systemImage: "exclamationmark.triangle")
                } description: {
                    Text(message.text).font(.caption)
                } actions: {
                    retryButton
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var queue: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                if !showEmptySections && store.shrItems.isEmpty && store.recentlyCreatedItems.isEmpty {
                    ContentUnavailableView {
                        Label(L10n.text(.commonNothingPending), systemImage: "checkmark.circle")
                    }
                }

                if showEmptySections || !store.shrItems.isEmpty {
                    Section {
                        if isSHRExpanded {
                            ForEach(store.shrItems) { workItem in
                                workItemRow(workItem)
                                    .padding(.top, QueueLayout.rowSpacing)
                            }
                        }
                    } header: {
                        QueueSectionHeader(
                            title: L10n.text(.jiraAwaitingSHR),
                            subtitle: nil,
                            symbol: "person.2",
                            tint: .orange,
                            count: store.shrItems.count,
                            isExpanded: isSHRExpanded,
                            accessibilityItemName: L10n.text(.jiraTickets)
                        ) {
                            withAnimation(.easeInOut(duration: 0.18)) {
                                isSHRExpanded.toggle()
                            }
                        }
                    }
                }

                if showEmptySections || !store.recentlyCreatedItems.isEmpty {
                    Section {
                        if isRecentlyCreatedExpanded {
                            ForEach(store.recentlyCreatedItems) { workItem in
                                workItemRow(workItem, showStatus: true)
                                    .padding(.top, QueueLayout.rowSpacing)
                            }
                        }
                    } header: {
                        QueueSectionHeader(
                            title: L10n.text(.jiraRecentlyCreated),
                            subtitle: nil,
                            symbol: "clock",
                            tint: .blue,
                            count: store.recentlyCreatedItems.count,
                            isExpanded: isRecentlyCreatedExpanded,
                            accessibilityItemName: L10n.text(.jiraTickets)
                        ) {
                            withAnimation(.easeInOut(duration: 0.18)) {
                                isRecentlyCreatedExpanded.toggle()
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, QueueLayout.sectionSpacing)
            .padding(.bottom, QueueLayout.sectionSpacing)
        }
    }

    private func workItemRow(_ workItem: JiraWorkItem, showStatus: Bool = false) -> some View {
        Button {
            guard let url = store.url(for: workItem) else { return }
            NSWorkspace.shared.open(url)
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text(workItem.title)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .padding(.trailing, 22)
                Text([workItem.key, workItem.issueType, showStatus ? workItem.status : nil]
                    .compactMap { $0 }
                    .joined(separator: " · "))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(store.url(for: workItem) == nil)
        .help(L10n.text(.jiraOpen, workItem.key))
        .overlay(alignment: .topTrailing) {
            if let site = store.siteURL {
                ItemNoteButton(itemID: .jira(key: workItem.key, site: site))
                    .padding(.trailing, 10)
                    .padding(.top, 6)
            }
        }
    }

    private var signedOut: some View {
        VStack(spacing: 10) {
            Image(systemName: "person.crop.circle.badge.exclamationmark")
                .font(.system(size: 30))
                .foregroundStyle(.secondary)
            Text(L10n.text(.jiraConnect))
                .font(.headline)

            HStack(spacing: 8) {
                Text(Self.loginCommand)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                Button {
                    copyLoginCommand()
                } label: {
                    Image(systemName: copiedLoginCommand ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .help(copiedLoginCommand ? L10n.text(.jiraCommandCopied) : L10n.text(.jiraCopyCommand))
                .accessibilityLabel(copiedLoginCommand ? L10n.text(.jiraCommandCopied) : L10n.text(.jiraCopyCommand))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))

            retryButton
        }
        .padding(16)
    }

    private var retryButton: some View {
        Button(L10n.text(.jiraCheckAgain)) { store.refresh() }
            .controlSize(.small)
            .disabled(store.isChecking)
    }

    private func copyLoginCommand() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(Self.loginCommand, forType: .string)
        copiedLoginCommand = true
    }
}
