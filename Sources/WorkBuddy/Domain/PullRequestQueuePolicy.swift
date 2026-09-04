import Foundation

/// Categorías de la cola de review, en orden de prioridad.
enum ReviewBucket: Int, CaseIterable, Sendable {
    case needsReview
    case approvedAlready

    var needsYourReview: Bool { self == .needsReview }
}

/// Reglas puras de negocio, compartidas por el panel, el badge y las notificaciones.
/// El alcance de la cola lo resuelve la búsqueda: pedidos a vos o a tus equipos.
enum PullRequestQueuePolicy {
    /// Sólo el veredicto agregado de GitHub confirma los approvals requeridos,
    /// incluyendo CODEOWNERS y branch protection. Contar approvals no alcanza.
    /// Un pedido al equipo equivale a uno personal. La antigüedad, la CI y haber
    /// comentado antes no cambian la categoría. Tu aprobación vigente sí te saca
    /// de ambas categorías de review, aunque falten approvals de otras personas.
    static func reviewBucket(for pullRequest: PullRequest) -> ReviewBucket? {
        guard !pullRequest.approvedByMe else { return nil }
        return pullRequest.reviewDecision == .approved ? .approvedAlready : .needsReview
    }
}

// MARK: - Agrupaciones

/// Viven acá y no en el store para que sean funciones puras sobre un array:
/// se pueden testear sin instanciar nada ni abrir un seam de test.
extension [PullRequest] {
    /// Saca los PRs con estos ids. Se compone antes de agrupar, así el filtro de
    /// ignorados vale también para el contador del badge.
    func excluding(_ ids: Set<String>) -> [PullRequest] {
        filter { !ids.contains($0.id) }
    }

    /// Deja sólo los PRs con estos ids.
    func only(_ ids: Set<String>) -> [PullRequest] {
        filter { ids.contains($0.id) }
    }

    /// PRs de personas, agrupados por bucket en orden de prioridad.
    var humanSections: [(bucket: ReviewBucket, items: [PullRequest])] {
        let humans = filter { !$0.author.isBot }
        let grouped = Dictionary(grouping: humans) { $0.bucket() }
        return ReviewBucket.allCases.compactMap { bucket in
            guard let items = grouped[bucket], !items.isEmpty else { return nil }
            return (bucket, items.sorted { $0.updatedAt > $1.updatedAt })
        }
    }

    /// Bots y cuentas de máquina: CI exitosa primero, luego actividad reciente.
    var automation: [PullRequest] {
        filter(\.author.isBot).sorted { $0.updatedAt > $1.updatedAt }
            .prioritizingSuccessfulCI
    }

    /// Partición estable: conserva favoritos y actividad dentro de cada grupo.
    var prioritizingSuccessfulCI: [PullRequest] {
        filter { $0.checks == .success } + filter { $0.checks != .success }
    }

    /// PRs que GitHub dejaría mergear y que te toca mergear a vos: los tuyos y
    /// los de automatización. Los de otras personas son de ellas para mergear,
    /// aunque estén aprobados.
    var readyToMerge: [PullRequest] {
        filter { ($0.authoredByMe || $0.author.isBot) && $0.isReadyToMerge }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    /// Sólo autoría personal con CI fallida. Incluye drafts y checks opcionales:
    /// un PR puede requerir un fix aunque GitHub permita mergearlo.
    var needingCIFix: [PullRequest] {
        filter { $0.authoredByMe && !$0.author.isBot && $0.checks.isRed }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    /// PRs de personas que esperan que los revises vos.
    ///
    /// Los de automatización quedan afuera a propósito: si el badge contara los
    /// 56 PRs de bots de la cola, dejarías de mirarlo.
    var awaitingYourReview: [PullRequest] {
        filter { !$0.author.isBot && $0.bucket()?.needsYourReview == true }
    }
}
