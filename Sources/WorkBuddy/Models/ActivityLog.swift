import Foundation
import Observation

/// Historial compartido de la sesión. Una operación conserva su identidad al
/// actualizar el progreso; cada ejecución nueva genera una entrada distinta.
@MainActor
@Observable
final class ActivityLog {
    enum Source {
        case manual, batch, autopilot
        var title: String {
            switch self {
            case .manual: L10n.text(.activityManual)
            case .batch: L10n.text(.activityBatch)
            case .autopilot: "Autopilot"
            }
        }
    }

    enum Status {
        case pending, checking, running, waiting(seconds: Int, attempt: Int)
        case succeeded, skipped(LocalizedMessage), failed(LocalizedMessage), uncertain(LocalizedMessage)

        var isComplete: Bool {
            switch self { case .succeeded, .skipped, .failed, .uncertain: true; default: false }
        }
        var isError: Bool { switch self { case .failed, .uncertain: true; default: false } }
        var needsVerification: Bool { if case .uncertain = self { true } else { false } }
        var isClearable: Bool { isComplete && !needsVerification }
        var text: String {
            switch self {
            case .pending: L10n.text(.batchPending)
            case .checking: L10n.text(.batchChecking)
            case .running: L10n.text(.activityRunning)
            case .waiting(let seconds, let attempt): L10n.text(.batchRetryWaiting, String(seconds), String(attempt))
            case .succeeded: L10n.text(.activityCompleted)
            case .skipped(let message), .failed(let message): message.text
            case .uncertain(let message): L10n.text(.activityUncertain, message.text)
            }
        }
    }

    struct Entry: Identifiable {
        let id: UUID
        let date: Date
        let title: LocalizedMessage
        let target: String
        let detail: String
        let url: URL?
        let symbol: String
        let source: Source
        var status: Status
        let action: PullRequestAction?
        let pullRequest: PullRequest?
        let viewer: String?

        var statusText: String {
            if case .succeeded = status, let action { return action.completedText }
            if case .failed(let message) = status, action?.batchAction != nil {
                return L10n.text(.activityNotExecuted, message.text)
            }
            return status.text
        }
    }

    private(set) var entries: [Entry] = []
    private(set) var unreadIDs: Set<UUID> = []
    private var isPresented = false
    private var isPanelVisible = true
    private var isVisible: Bool { isPresented && isPanelVisible }

    var runningCount: Int { entries.count {
        switch $0.status { case .checking, .running: true; default: false }
    } }
    var pendingCount: Int { entries.count { if case .pending = $0.status { true } else { false } } }
    var hasUnreadErrors: Bool { entries.contains { unreadIDs.contains($0.id) && $0.status.isError } }

    @discardableResult
    func record(id: UUID = UUID(), title: LocalizedMessage, target: String, detail: String = "",
                url: URL? = nil, symbol: String, source: Source = .manual,
                status: Status = .succeeded, date: Date = .now,
                action: PullRequestAction? = nil, pullRequest: PullRequest? = nil, viewer: String? = nil) -> UUID {
        if let index = entries.firstIndex(where: { $0.id == id }) {
            entries[index].status = status
        } else {
            entries.insert(Entry(id: id, date: date, title: title, target: target, detail: detail,
                                 url: url, symbol: symbol, source: source, status: status, action: action, pullRequest: pullRequest, viewer: viewer), at: 0)
        }
        if !isVisible { unreadIDs.insert(id) }
        return id
    }

    @discardableResult
    func record(_ action: PullRequestAction, on pr: PullRequest, status: Status = .succeeded, viewer: String? = nil) -> UUID {
        record(title: LocalizedMessage(action.title), target: "\(pr.repository) #\(pr.number)",
               detail: pr.title, url: pr.url, symbol: action.systemImage, status: status, action: action, pullRequest: pr, viewer: viewer)
    }

    func update(_ id: UUID, status: Status) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].status = status
        if !isVisible { unreadIDs.insert(id) }
    }

    func record(_ entry: PullRequestBatch.Entry, source: Source, viewer: String? = nil) {
        let status: Status
        switch entry.status {
        case .pending: status = .pending
        case .checking: status = .checking
        case .executing: status = .running
        case .waiting(let seconds, let attempt): status = .waiting(seconds: seconds, attempt: attempt)
        case .completed: status = .succeeded
        case .skipped(let reason): status = .skipped(LocalizedMessage(reason.text))
        case .failed(let message): status = .failed(message)
        case .uncertain(let message): status = .uncertain(message)
        }
        let pr = entry.pullRequest
        record(id: entry.activityID, title: LocalizedMessage(entry.candidate.action.title),
               target: "\(pr.repository) #\(pr.number)", detail: pr.title, url: pr.url,
               symbol: entry.candidate.action.symbol, source: source, status: status,
               action: entry.candidate.action.action, pullRequest: pr, viewer: viewer)
    }

    func needsVerification(for pr: PullRequest, viewer: String?) -> Bool {
        unconfirmedAction(for: pr, viewer: viewer) != nil
    }

    func unconfirmedAction(for pr: PullRequest, viewer: String?) -> Entry? {
        entries.first {
            $0.pullRequest?.id == pr.id && $0.pullRequest?.headRefOID == pr.headRefOID
                && $0.viewer?.lowercased() == viewer?.lowercased() && $0.status.needsVerification
        }
    }

    func setVisible(_ visible: Bool) {
        isPresented = visible
        if isVisible { unreadIDs = [] }
    }

    func setPanelVisible(_ visible: Bool) {
        isPanelVisible = visible
        if isVisible { unreadIDs = [] }
    }

    /// Limpiar no oculta operaciones en curso ni interrumpe su ejecución.
    func clearCompleted() {
        entries.removeAll { $0.status.isClearable }
        unreadIDs.formIntersection(Set(entries.map(\.id)))
    }
}
