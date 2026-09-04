import Foundation

/// Dos modos excluyentes: sólo los seleccionados, o todos menos los muteados.
struct RepositoryFilter: Codable, Equatable {
    private static let key = "repositoryFilter"

    private(set) var solo: Set<String> = []
    private(set) var muted: Set<String> = []

    var isActive: Bool { !solo.isEmpty || !muted.isEmpty }

    init() {}

    private enum CodingKeys: String, CodingKey { case solo, muted }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        // La versión anterior guardaba un único repo y podía conservar muteos
        // simultáneos. Se mantiene su selección visible, descartando los muteos.
        if let repositories = try? values.decode(Set<String>.self, forKey: .solo) {
            solo = Set(repositories.map { $0.lowercased() })
        } else if let repository = try values.decodeIfPresent(String.self, forKey: .solo) {
            solo = [repository.lowercased()]
        }
        if solo.isEmpty {
            muted = Set((try values.decodeIfPresent(Set<String>.self, forKey: .muted) ?? [])
                .map { $0.lowercased() })
        }
    }

    func includes(_ repository: String) -> Bool {
        let repository = repository.lowercased()
        if !solo.isEmpty { return solo.contains(repository) }
        return !muted.contains(repository)
    }

    func apply(to pullRequests: [PullRequest]) -> [PullRequest] {
        pullRequests.filter { includes($0.repository) }
    }

    mutating func toggleSolo(_ repository: String) {
        let repository = repository.lowercased()
        muted.removeAll()
        if !solo.insert(repository).inserted { solo.remove(repository) }
    }

    mutating func toggleMute(_ repository: String) {
        let repository = repository.lowercased()
        solo.removeAll()
        if !muted.insert(repository).inserted {
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
        let names = Set(grouped.keys).union(muted).union(solo)
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
