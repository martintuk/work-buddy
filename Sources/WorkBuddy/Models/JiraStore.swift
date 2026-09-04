import Foundation

@MainActor
@Observable
final class JiraStore {
    enum State: Equatable {
        case idle
        case checking
        case signedOut
        case authenticated
        case unavailable
        case failed(String)
    }

    private(set) var state: State = .idle
    private var inFlight: Task<Void, Never>?

    var isChecking: Bool { state == .checking }

    func refresh() {
        guard inFlight == nil else { return }
        state = .checking

        inFlight = Task {
            defer { inFlight = nil }
            do {
                state = switch try await ACLI.authenticationStatus() {
                case .authenticated: .authenticated
                case .signedOut: .signedOut
                }
            } catch ACLI.Failure.notInstalled {
                state = .unavailable
            } catch {
                state = .failed(
                    (error as? LocalizedError)?.errorDescription
                        ?? error.localizedDescription
                )
            }
        }
    }
}
