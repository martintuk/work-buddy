import Foundation

@MainActor
@Observable
final class JiraStore {
    enum State: Equatable {
        case idle
        case checking
        case signedOut
        case loaded
        case unavailable
        case failed(String)
    }

    private(set) var state: State = .idle
    private(set) var shrItems: [JiraWorkItem] = []
    private(set) var siteURL: URL?
    private(set) var lastUpdated: Date?
    private var inFlight: Task<Void, Never>?

    var isChecking: Bool { state == .checking }

    func refresh() {
        guard inFlight == nil else { return }
        state = .checking

        inFlight = Task {
            defer { inFlight = nil }
            do {
                switch try await ACLI.authenticationStatus() {
                case .authenticated(let site):
                    siteURL = site
                    shrItems = try await SHRQueue.fetch()
                    lastUpdated = .now
                    state = .loaded
                case .signedOut:
                    shrItems = []
                    siteURL = nil
                    lastUpdated = nil
                    state = .signedOut
                }
            } catch ACLI.Failure.notInstalled {
                state = .unavailable
            } catch ACLI.Failure.notAuthenticated {
                state = .signedOut
            } catch {
                state = .failed(
                    (error as? LocalizedError)?.errorDescription
                        ?? error.localizedDescription
                )
            }
        }
    }

    func url(for workItem: JiraWorkItem) -> URL? {
        siteURL?.appending(path: "browse").appending(path: workItem.key)
    }
}
