import Foundation
import Observation

/// Manual folder associations shared by every PR in a repository.
@MainActor
@Observable
final class LocalRepositoryStore {
    private static let defaultsKey = "localRepositoryFolders.v1"
    private let defaults: UserDefaults
    private var paths: [String: String]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        paths = defaults.dictionary(forKey: Self.defaultsKey) as? [String: String] ?? [:]
    }

    var repositories: Set<String> { Set(paths.keys) }

    func folder(for repository: String) -> URL? {
        paths[repository.lowercased()].map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    func associate(_ folder: URL, with repository: String) throws {
        let folder = folder.standardizedFileURL.resolvingSymlinksInPath()
        // .git can be a directory for a clone or a file for a worktree.
        guard folder.isFileURL,
              FileManager.default.fileExists(atPath: folder.appendingPathComponent(".git").path) else {
            throw FolderError.missingGitMetadata
        }
        paths[repository.lowercased()] = folder.path
        persist()
    }

    func removeFolder(for repository: String) {
        paths.removeValue(forKey: repository.lowercased())
        persist()
    }

    private func persist() {
        defaults.set(paths, forKey: Self.defaultsKey)
    }

    enum FolderError: LocalizedError {
        case missingGitMetadata

        var errorDescription: String? { L10n.text(.repositoriesInvalidFolder) }
    }
}
