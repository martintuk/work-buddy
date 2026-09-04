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
    let perform: (PullRequestAction) -> Void

    @State private var isHovering = false

    var body: some View {
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
                if isActing || isOpeningProject {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 18, height: 18)
                } else {
                    actionMenu
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
        .contentShape(.rect)
        .contextMenu {
            if !isActing {
                actionMenuItems
            }
        }
        .onHover { isHovering = $0 }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(pullRequest.title)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .padding(.trailing, 44)
            subtitle
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(.rect)
    }

    private var subtitle: some View {
        HStack(spacing: 5) {
            Text("\(pullRequest.shortRepository) #\(String(pullRequest.number))")
                .foregroundStyle(.secondary)
            Text("· \(pullRequest.author.login)")
                .foregroundStyle(.tertiary)
            badges
            Spacer(minLength: 4)
            Text(pullRequest.updatedAt, format: .relative(presentation: .numeric))
                .foregroundStyle(.tertiary)
        }
        .font(.system(size: 10))
        .lineLimit(1)
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
        if pullRequest.approvals > 0 {
            Badge(text: "\(pullRequest.approvals)✓", color: .green)
        }
        behindBadge
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

        // Sólo ofrecemos lo que puede funcionar. Un botón que sólo puede
        // fallar entrena a ignorar los errores.
        if pullRequest.canRequestDependabotRebase(behindBy: behindBy) {
            button(.dependabotRebase)
        }
        if pullRequest.canApprove {
            button(.approve)
        }
        if pullRequest.canRebase(behindBy: behindBy) {
            button(.rebase)
        }
        // `canMerge` es false cuando no tenemos datos de merge, que es el caso
        // de la cola de review: la acción aparece sólo en "Para
        // mergear". El método no se elige acá: lo define el repo.
        if pullRequest.canMerge {
            button(.merge)
        }

        if pullRequest.canApprove || pullRequest.canMerge
            || pullRequest.canRebase(behindBy: behindBy)
            || pullRequest.canRequestDependabotRebase(behindBy: behindBy) {
            Divider()
        }
        button(isIgnored ? .restore : .ignore)
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
