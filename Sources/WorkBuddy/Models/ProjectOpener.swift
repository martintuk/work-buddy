import Foundation
import Observation

/// Keep notices at section level, not in a row that may disappear during refresh.
@MainActor
@Observable
final class ProjectOpener {
    /// Fallback uses the original target: editor or agent.
    enum Target { case editor, agent }

    struct Warning {
        let request: LocalBranchCheckout.Request
        let target: Target
        let reason: Error
        var text: String { L10n.text(.editorBranchUnavailable, request.branch) }
    }

    private(set) var openingID: String?
    private(set) var warning: Warning?
    private(set) var error: Error?
    var isOpening: Bool { openingID != nil }

    private let checkout: @Sendable (LocalBranchCheckout.Request) async throws -> Void

    init(checkout: @escaping @Sendable (LocalBranchCheckout.Request) async throws -> Void = {
        try await LocalBranchCheckout.run($0)
    }) {
        self.checkout = checkout
    }

    func open(_ request: LocalBranchCheckout.Request, target: Target = .editor,
              launch: (URL) async throws -> Void) async {
        guard !isOpening else { return }
        dismissNotice()
        openingID = request.pullRequestID
        defer { openingID = nil }
        do {
            try await checkout(request)
        } catch let failure as LocalBranchCheckout.VerificationError {
            error = failure
            return // Do not offer to open code with a mismatched identity or revision.
        } catch {
            warning = Warning(request: request, target: target, reason: error)
            return // Opening without the branch always requires a user click.
        }
        await launchProject(request.folder, launch: launch)
    }

    func openWithoutBranch(launch: (URL) async throws -> Void) async {
        guard !isOpening, let warning else { return }
        self.warning = nil
        openingID = warning.request.pullRequestID
        defer { openingID = nil }
        await launchProject(warning.request.folder, launch: launch)
    }

    func dismissNotice() {
        warning = nil
        error = nil
    }

    private func launchProject(_ folder: URL, launch: (URL) async throws -> Void) async {
        do { try await launch(folder) }
        catch { self.error = error }
    }
}
