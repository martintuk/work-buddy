import AppKit
import SwiftUI

/// Una fila de la lista. Un click selecciona y doble click abre el PR; el menú de la derecha
/// y el menú contextual tienen el resto de las acciones.
struct PullRequestRow: View {
    let pullRequest: PullRequest
    let isSelected: Bool
    let select: () -> Void
    let isIgnored: Bool
    let isActing: Bool
    /// Commits atrás de la base. `nil` = no se pudo medir, que no es `0`.
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
    var actionStatus: ActivityLog.Status? = nil
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
            // Las acciones quedan fuera del área que reconoce los clicks de la fila.
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
                if let actionStatus {
                    ActivityStatusIcon(status: actionStatus)
                        .frame(width: 18, height: 18)
                        .help(actionStatus.text)
                        .accessibilityLabel(actionStatus.text)
                } else if isActing || isOpeningProject {
                    ProgressView().controlSize(.small).frame(width: 18, height: 18)
                }
                if !isActing && !isOpeningProject { actionMenu }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
        // El label queda fuera de los gestos de la fila, igual que las acciones.
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
        PullRequestSummary(pullRequest: pullRequest, titleTrailingPadding: actionStatus == nil ? 44 : 66, usesRepositoryOverlay: true) {
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
        // Informativo, no excluyente: statusCheckRollup incluye checks opcionales.
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
    }

    // El color refleja el veredicto global, independientemente del autor,
    // de quién aprobó y de la sección donde aparece el PR.
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

    /// Mostramos sólo atraso confirmado. Mientras se calcula o si no se pudo
    /// medir, omitimos el badge sin tratar el valor desconocido como cero.
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
        // Siempre presente para no mover el layout, atenuado hasta que pasás
        // el mouse por encima.
        .opacity(isHovering ? 1 : 0.25)
    }

    @ViewBuilder
    private var actionMenuItems: some View {
        button(.open)
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(pullRequest.url.absoluteString, forType: .string)
            repositoryStore.activity.record(title: LocalizedMessage(L10n.text(.commonCopyLink)),
                target: "\(pullRequest.repository) #\(pullRequest.number)", detail: pullRequest.title,
                url: pullRequest.url, symbol: "link")
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

        // Una colección dinámica identifica las inserciones y bajas de acciones
        // cuando cambia el PR, tanto en Menu como en el menú contextual.
        let writeActions = pullRequest.availableWriteActions(behindBy: behindBy)
        ForEach(writeActions) { action in
            button(action)
        }

        if !writeActions.isEmpty {
            Divider()
        }
        button(isIgnored ? .restore : .ignore)
    }

}

/// Selecciona la fila al presionar cualquier botón del mouse, antes de que
/// SwiftUI abra el menú contextual o el menú de acciones.
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
