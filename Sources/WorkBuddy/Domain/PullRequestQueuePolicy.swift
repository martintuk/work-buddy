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
    /// comentado antes no cambian la categoría de personas. La automatización
    /// con CI fallida queda en su sección. Dependabot espera CI exitosa,
    /// ausencia confirmada de conflictos y salida de draft. Tu aprobación vigente sí te saca
    /// de ambas categorías de review, aunque falten approvals de otras personas.
    static func reviewBucket(for pullRequest: PullRequest) -> ReviewBucket? {
        guard !pullRequest.author.isBot || !pullRequest.checks.isRed else { return nil }
        if pullRequest.author.isDependabot && !pullRequest.isReadyForDependabotReview { return nil }
        guard !pullRequest.approvedByMe else { return nil }
        return pullRequest.reviewDecision == .approved ? .approvedAlready : .needsReview
    }
}

// MARK: - Agrupaciones

/// Viven acá y no en el store para que sean funciones puras sobre un array:
/// se pueden testear sin instanciar nada ni abrir un seam de test.
extension [PullRequest] {
    func uniquedByID() -> [PullRequest] {
        var seen = Set<String>()
        return filter { seen.insert($0.id).inserted }
    }

    /// Saca los PRs con estos ids. Se compone antes de agrupar, así el filtro de
    /// ignorados vale también para el contador del badge.
    func excluding(_ ids: Set<String>) -> [PullRequest] {
        filter { !ids.contains($0.id) }
    }

    /// Deja sólo los PRs con estos ids.
    func only(_ ids: Set<String>) -> [PullRequest] {
        filter { ids.contains($0.id) }
    }

    /// Personas y automatización, agrupadas por review pendiente. Dependabot
    /// entra sólo cuando está listo para revisar.
    var reviewSections: [(bucket: ReviewBucket, items: [PullRequest])] {
        let grouped = Dictionary(grouping: self) { $0.bucket() }
        return ReviewBucket.allCases.compactMap { bucket in
            guard let items = grouped[bucket], !items.isEmpty else { return nil }
            return (bucket, items.sorted { $0.updatedAt > $1.updatedAt })
        }
    }

    /// Bots con CI fallida, Dependabot esperando condiciones de review, o bots
    /// aprobados por vos que esperan otra aprobación.
    var automation: [PullRequest] {
        filter {
            $0.author.isBot && ($0.checks.isRed || $0.awaitingOtherApproval
                || ($0.author.isDependabot && !$0.isReadyForDependabotReview))
        }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    /// La consulta de review no trae mergeabilidad. La de merge decide qué bots
    /// ya tienen su acción resuelta allí y no deben repetirse en review o automation.
    func excludingMergeableAutomation(in mergeCandidates: [PullRequest]) -> [PullRequest] {
        excluding(Set(mergeCandidates.readyToMerge.filter(\.author.isBot).map(\.id)))
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

    /// Los mismos PRs que muestra Para revisar cuentan en el badge y notifican.
    var awaitingYourReview: [PullRequest] {
        filter { $0.bucket()?.needsYourReview == true }
    }
}
