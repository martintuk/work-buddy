import Foundation

/// All organizations for the authenticated account, including every page.
enum GitHubOrganizations {
    private struct Organization: Decodable {
        let login: String
    }

    static func fetch() async throws -> [String] {
        try await GH.preflight()
        let data = try await GH.runRetrying([
            "api", "user/orgs?per_page=100", "--paginate", "--slurp"
        ])
        return try decode(data)
    }

    static func decode(_ data: Data) throws -> [String] {
        do {
            let pages = try JSONDecoder().decode([[Organization]].self, from: data)
            return Set(pages.flatMap { $0.map { $0.login.lowercased() } }).sorted()
        } catch {
            throw GH.Failure.badJSON(error.localizedDescription)
        }
    }
}
