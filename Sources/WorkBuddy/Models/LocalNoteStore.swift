import Foundation
import Observation

/// Identidad local, independiente de la sección en la que aparece el ítem.
struct LocalNoteID: Hashable {
    let storageKey: String

    static func github(nodeID: String, host: String) -> Self {
        make(["github", host.lowercased(), nodeID])
    }

    static func jira(key: String, site: URL) -> Self {
        let host = site.host()?.lowercased() ?? site.absoluteString
        let port = site.port.map { ":\($0)" } ?? ""
        let path = site.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return make(["jira", host + port, path, key.uppercased()])
    }

    private static func make(_ components: [String]) -> Self {
        // Length-prefixing avoids collisions even if a component contains separators.
        Self(storageKey: components.map { "\($0.utf8.count):\($0)" }.joined())
    }
}

/// Notas privadas de esta instalación. Nunca forman parte de modelos ni payloads remotos.
@MainActor
@Observable
final class LocalNoteStore {
    static let shared = LocalNoteStore()
    private static let defaultsKey = "localItemNotes.v1"

    private let defaults: UserDefaults
    private var notes: [String: String]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        notes = defaults.dictionary(forKey: Self.defaultsKey) as? [String: String] ?? [:]
    }

    func text(for id: LocalNoteID) -> String {
        notes[id.storageKey] ?? ""
    }

    func setText(_ text: String, for id: LocalNoteID) {
        guard text != self.text(for: id) else { return }
        if text.isEmpty {
            notes.removeValue(forKey: id.storageKey)
        } else {
            notes[id.storageKey] = text
        }
        // Persist each edit, including when a refresh removes the row while editing.
        // Notes are not pruned when an item leaves a queue or is hidden by a filter.
        defaults.set(notes, forKey: Self.defaultsKey)
    }
}
