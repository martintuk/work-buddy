import Foundation

/// Cuántos commits atrás está la rama de cada PR respecto de su base.
///
/// **Por qué no alcanza `mergeStateStatus`.** Esa flag sólo dice `BEHIND` cuando
/// el repo exige ramas actualizadas, y la mayoría de estos repos no lo exige: una
/// rama 10 commits atrás sigue leyendo `BLOCKED`. Medido sobre 20 PRs de
/// dependabot de la org, la flag ve **1 de 4** atrasados.
///
/// **Por qué GraphQL y no la compare API de REST.** REST devuelve el diff
/// completo —27 KB por PR, medido— y `per_page` no lo reduce, porque el bulto son
/// los `files`. `Ref.compare` devuelve sólo el número, y se batchea con alias:
/// para 20 PRs, **820 bytes en una request** contra 540 KB en veinte.
enum BehindCount {
    /// Comparaciones por request. Con 20 la respuesta tarda ~3.8s; es la razón de
    /// que esto corra como segunda fase y no bloqueando el dibujado del panel.
    static let batchSize = 20

    /// - Returns: `behindBy` por id de PR. Un PR **ausente** del diccionario es
    ///   "no medido", que no es lo mismo que `0` = "al día". Confundirlos es lo
    ///   que convierte el rebase en una adivinanza.
    static func fetch(for pullRequests: [PullRequest]) async -> [String: Int] {
        var results: [String: Int] = [:]
        let comparable = pullRequests.filter {
            isSafeRef($0.baseRefName) && isSafeRef($0.headRefName)
        }

        for batch in comparable.chunked(into: batchSize) {
            guard let data = try? await GH.runRetrying(
                ["api", "graphql", "-f", "query=\(query(for: batch))"]
            ) else {
                // Un batch que falla deja esos PRs sin medir, y eso se ve en la
                // UI. Preferimos eso antes que reportar 0 y mentir.
                continue
            }
            guard let response = try? JSONDecoder.github.decode(BatchResponse.self, from: data)
            else { continue }

            // GraphQL puede devolver `data` parcial junto con `errors` — por
            // ejemplo si un repo se archivó. Tomamos lo que resolvió.
            for (index, pullRequest) in batch.enumerated() {
                if let behind = response.data?["p\(index)"]??.ref?.compare?.behindBy {
                    results[pullRequest.id] = behind
                }
            }
        }
        return results
    }

    /// Un alias de `repository` por PR, todos en una request.
    static func query(for pullRequests: [PullRequest]) -> String {
        let fields = pullRequests.enumerated().map { index, pullRequest in
            let parts = pullRequest.repository.split(separator: "/", maxSplits: 1)
            let owner = parts.first.map(String.init) ?? ""
            let name = parts.count > 1 ? String(parts[1]) : ""
            return """
            p\(index): repository(owner: "\(owner)", name: "\(name)") {
              ref(qualifiedName: "\(pullRequest.baseRefName)") {
                compare(headRef: "\(pullRequest.headRefName)") { behindBy }
              }
            }
            """
        }
        return "query {\n\(fields.joined(separator: "\n"))\n}"
    }

    /// Un ref de git no puede contener comillas, barras invertidas ni espacios,
    /// así que interpolarlo en la query es seguro. Lo verificamos igual: si eso
    /// cambiara, es mejor no medir que emitir una query malformada.
    static func isSafeRef(_ ref: String) -> Bool {
        !ref.isEmpty && !ref.contains { "\"\\ \n\t\r".contains($0) }
    }
}

// MARK: - Respuesta

/// Los alias son claves dinámicas (`p0`, `p1`, …), así que `data` se decodifica
/// como diccionario en vez de una struct con campos fijos.
private struct BatchResponse: Decodable {
    let data: [String: Entry?]?

    struct Entry: Decodable {
        let ref: Ref?

        struct Ref: Decodable {
            let compare: Comparison?

            struct Comparison: Decodable {
                let behindBy: Int
            }
        }
    }
}

private extension Array {
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return [self] }
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0 ..< Swift.min($0 + size, count)])
        }
    }
}
