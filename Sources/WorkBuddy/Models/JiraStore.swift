import Foundation

@MainActor
@Observable
final class JiraStore {
    enum State {
        case idle
        case checking
        case signedOut
        case loaded
        case unavailable
        case failed(LocalizedMessage)
    }

    private(set) var state: State = .idle
    private(set) var shrItems: [JiraWorkItem] = []
    private(set) var recentlyCreatedItems: [JiraWorkItem] = []
    private(set) var siteURL: URL?
    private(set) var lastUpdated: Date?
    private var inFlight: Task<Void, Never>?

    var isChecking: Bool {
        if case .checking = state { return true }
        return false
    }

    func refresh() {
        guard inFlight == nil else { return }
        state = .checking

        inFlight = Task {
            defer { inFlight = nil }
            do {
                switch try await ACLI.authenticationStatus() {
                case .authenticated(let site):
                    siteURL = site
                    async let shr = SHRQueue.fetch()
                    async let recentlyCreated = RecentlyCreatedQueue.fetch()
                    (shrItems, recentlyCreatedItems) = try await (shr, recentlyCreated)
                    lastUpdated = .now
                    state = .loaded
                case .signedOut:
                    shrItems = []
                    recentlyCreatedItems = []
                    siteURL = nil
                    lastUpdated = nil
                    state = .signedOut
                }
            } catch ACLI.Failure.notInstalled {
                state = .unavailable
            } catch ACLI.Failure.notAuthenticated {
                state = .signedOut
            } catch {
                state = .failed(LocalizedMessage(error.localizedDescription))
            }
        }
    }

    func url(for workItem: JiraWorkItem) -> URL? {
        siteURL?.appending(path: "browse").appending(path: workItem.key)
    }
}
