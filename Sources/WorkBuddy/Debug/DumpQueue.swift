import Foundation

/// Volcado de la cola de review por stdout. Sólo para desarrollo: nos deja
/// verificar la capa de datos y el bucketing sin depender de la GUI.
enum DumpQueue {
    @MainActor
    static func run() async {
        do {
            try await GH.preflight()
            let start = Date()
            let configuration = AppConfiguration.load()

            // Las consultas de las cuatro colas son independientes. La app las escalona (primero
            // personas, después dependabot) para que el panel aparezca antes;
            // acá van en paralelo porque sólo interesa el resultado.
            async let reviewQueue = ReviewQueue.fetch(configuration: configuration)
            async let dependabotQueue = DependabotQueue.fetch(configuration: configuration)
            async let mergeQueue = MergeQueue.fetch(configuration: configuration)
            async let fixQueue = FixQueue.fetch(configuration: configuration)

            let humans = try await reviewQueue
            let dependabot = try await dependabotQueue
            let mergeCandidates = try await mergeQueue
            let fixCandidates = try await fixQueue
            let replyCandidates = try await ReplyQueue.fetch(for: fixCandidates)
            let pullRequests = humans + dependabot
            let elapsed = Date().timeIntervalSince(start)

            // Aplicamos la lista de ignorados igual que el panel, así el volcado
            // refleja lo que se ve en la app.
            let ignoredIDs = IgnoreList().ids
            let visible = pullRequests.excluding(ignoredIDs)
            let readyToMerge = mergeCandidates.excluding(ignoredIDs).readyToMerge
            let needingCIFix = fixCandidates.excluding(ignoredIDs).needingCIFix
            let needingReply = replyCandidates.excluding(ignoredIDs)

            var seen: Set<String> = []
            let allKnown = (pullRequests + mergeCandidates + fixCandidates)
                .filter { seen.insert($0.id).inserted }
            let ignored = allKnown.only(ignoredIDs)
            let behind = await BehindCount.fetch(for: allKnown)

            let people = visible.filter { !$0.author.isBot }
            let bots = visible.filter(\.author.isBot)

            // Mismo cálculo que el badge: las cuatro fuentes, deduplicadas por id.
            let awaiting = visible.awaitingYourReview
            let badge = Set(awaiting.map(\.id)).union(readyToMerge.map(\.id))
                .union(needingCIFix.map(\.id)).union(needingReply.map(\.id)).count

            print("\(pullRequests.count) PRs con review pedido — \(format(elapsed))")
            print("  personas: \(humans.count)  |  dependabot: \(dependabot.count)")
            print("visibles → personas: \(people.count)"
                + "  |  automatización: \(bots.count)"
                + "  |  ignorados: \(ignored.count)")
            print("BADGE: \(badge)  (\(awaiting.count) para revisar + "
                + "\(readyToMerge.count) para mergear + \(needingCIFix.count) para fixear + \(needingReply.count) para responder)\n")

            print("── LISTOS PARA MERGEAR (\(readyToMerge.count)) ──")
            for pullRequest in readyToMerge {
                print("  \(describe(pullRequest, behind: behind))  "
                    + "[\(pullRequest.mergeStateStatus?.rawValue ?? "?")]")
            }
            print("")

            print("── PARA FIXEAR (\(needingCIFix.count)) ──")
            for pullRequest in needingCIFix {
                print("  \(describe(pullRequest, behind: behind))")
            }
            print("")

            print("── PARA RESPONDER (\(needingReply.count)) ──")
            for pullRequest in needingReply {
                print("  \(describe(pullRequest, behind: behind))")
            }
            print("")

            print("── PERSONAS ──")
            printBuckets(people, behind: behind, listing: true)

            // Se listan igual que las personas: desde que dependabot entra al
            // panel, su atraso contra la base es el dato que decide si hace falta
            // un rebase, y no verlo acá sería volar a ciegas.
            print("── AUTOMATIZACIÓN ──")
            printBuckets(bots, behind: behind, listing: true)

            if !ignored.isEmpty {
                print("── IGNORADOS ──")
                printBuckets(ignored, behind: behind, listing: true)
            }
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            FileHandle.standardError.write(Data("Error: \(message)\n".utf8))
            exit(1)
        }
    }

    private static func printBuckets(
        _ pullRequests: [PullRequest],
        behind: [String: Int],
        listing: Bool
    ) {
        let grouped = Dictionary(grouping: pullRequests) { $0.bucket() }
        for bucket in ReviewBucket.allCases {
            let items = grouped[bucket] ?? []
            guard !items.isEmpty else { continue }
            print("\(bucket.title) (\(items.count))")
            guard listing else { continue }
            for pullRequest in items.sorted(by: { $0.updatedAt > $1.updatedAt }) {
                print("  \(describe(pullRequest, behind: behind))")
            }
        }
        // Siguen disponibles para automatización, merge e ignorados, aunque
        // ya no pertenecen a ninguna categoría de review del panel.
        let approvedByMe = pullRequests.filter(\.approvedByMe)
        if !approvedByMe.isEmpty {
            print("Aprobados por vos, fuera de la cola de review (\(approvedByMe.count))")
            if listing {
                for pullRequest in approvedByMe.sorted(by: { $0.updatedAt > $1.updatedAt }) {
                    print("  \(describe(pullRequest, behind: behind))")
                }
            }
        }
        print("")
    }

    private static func describe(_ pullRequest: PullRequest, behind: [String: Int]) -> String {
        // "?" es no medido y "" es al día: son estados distintos.
        let atraso: String? = switch behind[pullRequest.id] {
        case .some(let commits) where commits > 0: "↓\(commits)"
        case .none: "↓?"
        default: nil
        }
        let flags = [
            pullRequest.checks.isRed ? "CI✗" : nil,
            pullRequest.isDraft ? "draft" : nil,
            pullRequest.approvals > 0 ? "\(pullRequest.approvals)✓" : nil,
            atraso
        ].compactMap(\.self).joined(separator: " ")
        return "\(pullRequest.shortRepository)#\(pullRequest.number) "
            + "@\(pullRequest.author.login) — \(pullRequest.title.prefix(46)) \(flags)"
    }

    private static func format(_ seconds: TimeInterval) -> String {
        String(format: "%.1fs", seconds)
    }
}
