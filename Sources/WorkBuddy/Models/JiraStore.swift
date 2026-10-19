import Foundation

@MainActor
@Observable
final class JiraStore {
    enum State {
        case idle, checking, signedOut, loaded, unavailable
        case failed(LocalizedMessage)
    }

    private(set) var configuration: JiraConfiguration
    private(set) var state: State = .idle
    private(set) var primaryItems: [JiraWorkItem] = []
    private(set) var recentlyCreatedItems: [JiraWorkItem] = []
    private(set) var siteURL: URL?
    private(set) var lastUpdated: Date?
    private var inFlight: Task<Void, Never>?
    private var generation = UUID()
    private let defaults: UserDefaults
    private let authenticate: @Sendable () async throws -> ACLI.AuthenticationStatus
    private let loadQueue: @Sendable (String, String, Int?) async throws -> [JiraWorkItem]

    init(defaults: UserDefaults = .standard,
         authenticate: @escaping @Sendable () async throws -> ACLI.AuthenticationStatus = { try await ACLI.authenticationStatus() },
         loadQueue: @escaping @Sendable (String, String, Int?) async throws -> [JiraWorkItem] = {
             try await JiraQueue.fetch(jql: $0, title: $1, limit: $2)
         }) {
        self.defaults = defaults
        configuration = JiraConfiguration.load(defaults: defaults)
        self.authenticate = authenticate
        self.loadQueue = loadQueue
    }

    var isEnabled: Bool { configuration.isEnabled }
    var isChecking: Bool {
        if case .checking = state { return true }
        return false
    }

    func setEnabled(_ enabled: Bool) throws {
        var updated = configuration
        updated.isEnabled = enabled
        try configure(updated)
    }

    func configure(_ updated: JiraConfiguration) throws {
        let valid = try updated.validated()
        guard valid != configuration else { return }
        try valid.persist(defaults: defaults)
        configuration = valid
        generation = UUID()
        inFlight?.cancel()
        inFlight = nil
        clearSnapshot()
        state = .idle
        if isEnabled { refresh() }
    }

    func refresh() {
        guard isEnabled, inFlight == nil else { return }
        state = .checking
        let requestID = generation
        let config = configuration
        let authenticate = self.authenticate
        let loadQueue = self.loadQueue
        inFlight = Task {
            guard accepts(requestID) else { return }
            await Diagnostics.refresh(.jira) {
                defer { if generation == requestID { inFlight = nil } }
                do {
                    let authentication = try await Diagnostics.measure(.jiraAuth, operation: authenticate)
                    guard accepts(requestID) else { return }
                    switch authentication {
                    case .authenticated(let site):
                        siteURL = site
                        async let primary = Diagnostics.measure(.jiraPrimary) {
                            try Task.checkCancellation()
                            return try await loadQueue(config.primaryJQL, config.primaryTitle, nil)
                        }
                        async let recentlyCreated = Diagnostics.measure(.jiraRecent) {
                            try Task.checkCancellation()
                            return try await loadQueue(config.recentJQL, config.recentTitle, 10)
                        }
                        let (items, recentItems) = try await (primary, recentlyCreated)
                        guard accepts(requestID) else { return }
                        primaryItems = items
                        recentlyCreatedItems = recentItems
                        lastUpdated = .now
                        state = .loaded
                        Diagnostics.record(.published, metrics: [.items: items.count + recentItems.count])
                        Diagnostics.record(.queuesLoaded)
                    case .signedOut:
                        clearSnapshot()
                        state = .signedOut
                        Diagnostics.record(.signedOut)
                    }
                } catch {
                    guard accepts(requestID) else { return }
                    switch error {
                    case ACLI.Failure.notInstalled:
                        state = .unavailable
                        Diagnostics.record(.unavailable)
                    case ACLI.Failure.notAuthenticated:
                        clearSnapshot()
                        state = .signedOut
                        Diagnostics.record(.signedOut)
                    default:
                        Diagnostics.record(.failed, error: error)
                        state = .failed(LocalizedMessage(error.localizedDescription))
                    }
                }
            }
        }
    }

    private func accepts(_ requestID: UUID) -> Bool {
        isEnabled && generation == requestID && !Task.isCancelled
    }

    private func clearSnapshot() {
        primaryItems = []
        recentlyCreatedItems = []
        siteURL = nil
        lastUpdated = nil
    }

    func url(for workItem: JiraWorkItem) -> URL? {
        siteURL?.appending(path: "browse").appending(path: workItem.key)
    }
}
