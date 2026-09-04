import Foundation
import Observation

/// El aviso vive en la sección, no en una fila que puede desaparecer al refrescar.
@MainActor
@Observable
final class ProjectOpener {
    struct Warning {
        let request: LocalBranchCheckout.Request
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

    func open(_ request: LocalBranchCheckout.Request, launch: (URL) async throws -> Void) async {
        guard !isOpening else { return }
        dismissNotice()
        openingID = request.pullRequestID
        defer { openingID = nil }
        do {
            try await checkout(request)
        } catch {
            warning = Warning(request: request, reason: error)
            return // Abrir sin el branch siempre requiere el click del usuario.
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
