import Foundation

/// Solo es exclusivo y tiene prioridad sobre los muteos, que se conservan.
struct RepositoryFilter: Codable, Equatable {
    private static let key = "repositoryFilter"

    private(set) var solo: String?
    private(set) var muted: Set<String> = []

    var isActive: Bool { solo != nil || !muted.isEmpty }

    func includes(_ repository: String) -> Bool {
        let repository = repository.lowercased()
        if let solo { return solo == repository }
        return !muted.contains(repository)
    }

    func apply(to pullRequests: [PullRequest]) -> [PullRequest] {
        pullRequests.filter { includes($0.repository) }
    }

    mutating func toggleSolo(_ repository: String) {
        let repository = repository.lowercased()
        solo = solo == repository ? nil : repository
    }

    mutating func toggleMute(_ repository: String) {
        let repository = repository.lowercased()
        // Mutear el repo en solo vuelve a la mezcla, dejando ese repo muteado.
        if solo == repository {
            solo = nil
            muted.insert(repository)
        } else if !muted.insert(repository).inserted {
            muted.remove(repository)
        }
    }

    struct Repository: Identifiable {
        let id: String
        let pullRequestCount: Int
    }

    /// Distinct sobre los resultados SIN filtrar. Incluye preferencias sin
    /// resultados para poder deshacer un solo o mute tras un reinicio.
    func repositories(in pullRequests: [PullRequest]) -> [Repository] {
        let grouped = Dictionary(grouping: pullRequests) { $0.repository.lowercased() }
        var names = Set(grouped.keys).union(muted)
        if let solo { names.insert(solo) }
        return names.sorted().map { name in
            Repository(id: name, pullRequestCount: Set((grouped[name] ?? []).map(\.id)).count)
        }
    }

    static func load(defaults: UserDefaults = .standard) -> Self {
        guard let data = defaults.data(forKey: key),
              let filter = try? JSONDecoder().decode(Self.self, from: data) else { return Self() }
        return filter
    }

    func persist(defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.key)
    }
}
