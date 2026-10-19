import AppKit
import SwiftUI

/// A list row: click to select, double-click to open the PR. The trailing and context menus provide other actions.
struct PullRequestRow: View {
    let pullRequest: PullRequest
    let isSelected: Bool
    let select: () -> Void
    let isIgnored: Bool
    let isActing: Bool
    /// Commits behind the base. `nil` means unmeasured, distinct from zero.
    let behindBy: Int?
    let localFolder: URL?
    let editor: EditorStore
    let agentCLI: AgentCLIStore
    let requestEditorConfiguration: () -> Void
    let requestFolderConfiguration: () -> Void
    let isOpeningProject: Bool
    let canOpenProject: Bool
    let openProject: () -> Void
    let openAgent: () -> Void
    let repositoryStore: ReviewQueueStore
    var batchSelection: PullRequestBatchSelection? = nil
    let perform: (PullRequestAction) -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 0) {
            if let batchSelection {
                Button(action: batchSelection.toggle) {
                    Image(systemName: batchSelection.isSelected ? "checkmark.square.fill" : "square")
                        .font(.system(size: 14))
                        .foregroundStyle(batchSelection.isSelected ? Color.accentColor : Color.secondary)
                        .frame(width: 28, height: 30)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .disabled(!batchSelection.canSelect)
                .help(L10n.text(batchSelection.canSelect ? .batchSelect : .batchUnavailable))
                .accessibilityLabel("\(L10n.text(.batchSelect)): \(pullRequest.shortRepository) #\(pullRequest.number)")
                .accessibilityValue(L10n.text(batchSelection.isSelected ? .batchSelected : .batchNotSelected))
            }
            rowContent
        }
    }

    private var rowContent: some View {
        ZStack(alignment: .topTrailing) {
            // Keep actions outside the row's click recognition area.
            details
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .modifier(QueueItemInteraction(
                    isSelected: isSelected,
                    isHovering: isHovering,
                    openTitle: PullRequestAction.open.title,
                    select: select,
                    open: { perform(.open) }
                ))

            HStack(spacing: 4) {
                ItemNoteButton(
                    itemID: .github(nodeID: pullRequest.id, host: pullRequest.url.host() ?? "github.com"),
                    isRowHovering: isHovering
                )
                if isActing || isOpeningProject {
                    ProgressView().controlSize(.small).frame(width: 18, height: 18)
                }
                if !isActing && !isOpeningProject { actionMenu }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
        // Like actions, the label stays outside row gestures.
        .overlayPreferenceValue(RepositoryLabelBounds.self) { anchor in
            GeometryReader { geometry in
                if let anchor {
                    let bounds = geometry[anchor]
                    RepositoryQuickFilterButton(repository: pullRequest.repository, store: repositoryStore)
                        .font(.system(size: 10))
                        .frame(width: bounds.width, height: bounds.height, alignment: .leading)
                        .position(x: bounds.midX, y: bounds.midY)
                }
            }
        }
        .contentShape(.rect)
        .background(RowMouseSelection(select: select))
        .contextMenu {
            if !isActing {
                actionMenuItems
            }
        }
        .onHover { isHovering = $0 }
    }

    private var details: some View {
        PullRequestSummary(pullRequest: pullRequest, titleTrailingPadding: 44, usesRepositoryOverlay: true) {
            Text("· \(pullRequest.author.login)")
                .foregroundStyle(.tertiary)
            badges
            Spacer(minLength: 4)
            Text(pullRequest.updatedAt, format: .relative(presentation: .numeric))
                .foregroundStyle(.tertiary)
        }
    }

    @ViewBuilder
    private var badges: some View {
        if pullRequest.isDraft {
            Badge(text: L10n.text(.prDraft), color: .secondary)
        }
        // Informational, not a filter: statusCheckRollup includes optional checks.
        if pullRequest.checks.isRed {
            Badge(text: L10n.text(.prCI), color: .red)
        }
        if pullRequest.approvals > 0 || pullRequest.awaitingOtherApproval {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(approvalColor)
                .help(approvalHelp)
                .accessibilityLabel(approvalHelp)
        }
        behindBadge
        lineChanges
    }

    @ViewBuilder
    private var lineChanges: some View {
        if let additions = pullRequest.additions, let deletions = pullRequest.deletions {
            let help = L10n.text(.prLineChanges, String(additions), String(deletions))
            HStack(spacing: 3) {
                Text("+\(additions)").foregroundStyle(.green)
                Text("−\(deletions)").foregroundStyle(.red)
            }
            .monospacedDigit()
            .help(help)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(help)
        }
    }

    // Color reflects the overall verdict, regardless of author, approver, or PR section.
    private var approvalColor: Color {
        switch pullRequest.reviewDecision {
        case .approved: .green
        case .reviewRequired: .orange
        case .changesRequested: .red
        case nil: .secondary
        }
    }

    private var approvalHelp: String {
        let count = L10n.text(.prApprovalCount, String(pullRequest.approvals))
        let status: L10n.Key = switch pullRequest.reviewDecision {
        case .approved: .prApprovalsSatisfied
        case .reviewRequired: .prApprovalsRequired
        case .changesRequested: .prChangesRequested
        case nil: .prApprovalStatusUnknown
        }
        return "\(count). \(L10n.text(status))"
    }

    /// Show only confirmed lag. Omit the badge while measuring or after a failed measurement without treating unknown values as zero.
    @ViewBuilder
    private var behindBadge: some View {
        if let commits = behindBy, commits > 0 {
            Badge(text: "↓\(commits)", color: .orange)
                .help(L10n.text(commits == 1 ? .prBehindOne : .prBehindMany, String(commits), pullRequest.baseRefName))
        }
    }

    private var actionMenu: some View {
        Menu {
            actionMenuItems
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 18, height: 18)
                .contentShape(.rect)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel(L10n.text(.prActions))
        // Always present to keep layout stable, dimmed until hovered.
        .opacity(isHovering ? 1 : 0.25)
    }

    @ViewBuilder
    private var actionMenuItems: some View {
        button(.open)
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(pullRequest.url.absoluteString, forType: .string)
        } label: {
            Label(L10n.text(.commonCopyLink), systemImage: "link")
        }
        Button {
            if localFolder == nil {
                requestFolderConfiguration()
            } else if editor.selectedURL == nil {
                requestEditorConfiguration()
            } else {
                openProject()
            }
        } label: {
            Label(editor.selectedName.map { L10n.text(.editorOpenIn, $0) }
                ?? L10n.text(.editorOpen), systemImage: "chevron.left.forwardslash.chevron.right")
        }
        .help(localFolder?.path ?? L10n.text(.repositoriesNoFolder))
        .disabled(!canOpenProject)

        Button(action: openAgent) {
            Label(agentCLI.openTitle, systemImage: "terminal")
        }
        .help(localFolder?.path ?? L10n.text(.repositoriesNoFolder))
        .disabled(!canOpenProject)

        Divider()

        // A dynamic collection identifies inserted and removed actions when the PR changes, in both Menu and the context menu.
        let writeActions = repositoryStore.availableWriteActions(for: pullRequest)
        let actionToVerify = repositoryStore.actionToVerify(for: pullRequest)
        if let entry = actionToVerify {
            Button {
                Task { await repositoryStore.verifyAction(entry.id) }
            } label: {
                Label(L10n.text(.prVerifyResult), systemImage: "arrow.clockwise.circle")
            }
            .help(entry.statusText)
        }
        ForEach(writeActions) { action in
            button(action)
        }

        if !writeActions.isEmpty || actionToVerify != nil {
            Divider()
        }
        button(isIgnored ? .restore : .ignore)
    }

}

/// Select the row on any mouse button press, before SwiftUI opens the context or actions menu.
private struct RowMouseSelection: NSViewRepresentable {
    let select: () -> Void

    func makeNSView(context: Context) -> SelectionView {
        SelectionView()
    }

    func updateNSView(_ view: SelectionView, context: Context) {
        view.select = select
    }

    static func dismantleNSView(_ view: SelectionView, coordinator: ()) {
        view.stopMonitoring()
    }

    final class SelectionView: NSView {
        var select: () -> Void = {}
        private var monitor: Any?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stopMonitoring()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
                guard let self, let window = self.window, event.window === window,
                      self.bounds.contains(self.convert(event.locationInWindow, from: nil)) else {
                    return event
                }
                self.select()
                return event
            }
        }

        func stopMonitoring() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
        }
    }
}

private extension PullRequestRow {
    func button(_ action: PullRequestAction) -> some View {
        Button { perform(action) } label: {
            Label(action.title, systemImage: action.systemImage)
        }
    }
}

private struct Badge: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.system(size: 9, weight: .semibold))
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(color.opacity(0.15), in: RoundedRectangle(cornerRadius: 3))
            .foregroundStyle(color)
    }
}

struct PullRequestBatchSelection {
    let isSelected: Bool
    let canSelect: Bool
    let toggle: () -> Void
}
