import AppKit
import SwiftUI

/// Una fila de la lista. Clickear el cuerpo abre el PR; el menú de la derecha
/// tiene el resto de las acciones.
struct PullRequestRow: View {
    let pullRequest: PullRequest
    let isIgnored: Bool
    let isActing: Bool
    /// Commits atrás de la base. `nil` = no se pudo medir, que no es `0`.
    let behindBy: Int?
    let perform: (PullRequestAction) -> Void

    @State private var isHovering = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            // El cuerpo y el menú son hermanos, no anidados: un Menu adentro de
            // un Button no recibe los clicks.
            Button { perform(.open) } label: { details }
                .buttonStyle(.plain)

            if isActing {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 18, height: 18)
            } else {
                actionMenu
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isHovering ? Color.primary.opacity(0.07) : .clear)
        )
        .opacity(isIgnored ? 0.55 : 1)
        .onHover { isHovering = $0 }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(pullRequest.title)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .padding(.trailing, 22)
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
            Badge(text: "draft", color: .secondary)
        }
        // Informativo, no excluyente: statusCheckRollup incluye checks opcionales.
        if pullRequest.checks.isRed {
            Badge(text: "CI", color: .red)
        }
        if pullRequest.approvals > 0 {
            Badge(text: "\(pullRequest.approvals)✓", color: .green)
        }
        behindBadge
    }

    /// Tres estados distintos, a propósito: atrasado, al día, y no medido. Si
    /// "no medido" se viera igual que "al día", no habría forma de saber por qué
    /// no aparece la acción de rebase.
    @ViewBuilder
    private var behindBadge: some View {
        switch behindBy {
        case .some(let commits) where commits > 0:
            Badge(text: "↓\(commits)", color: .orange)
                .help("\(commits) commit\(commits == 1 ? "" : "s") atrás de \(pullRequest.baseRefName)")
        case .none:
            Badge(text: "↓?", color: .secondary)
                .help("No pude comparar contra \(pullRequest.baseRefName)")
        default:
            EmptyView() // al día: no hace falta decirlo
        }
    }

    private var actionMenu: some View {
        Menu {
            button(.open)

            // Sólo ofrecemos lo que puede funcionar. Un botón que sólo puede
            // fallar entrena a ignorar los errores.
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

            Divider()
            button(isIgnored ? .restore : .ignore)
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 18, height: 18)
                .contentShape(.rect)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("Acciones")
        // Siempre presente para no mover el layout, atenuado hasta que pasás
        // el mouse por encima.
        .opacity(isHovering ? 1 : 0.25)
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
