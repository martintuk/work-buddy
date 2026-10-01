import Foundation
import Observation

/// Historial local persistente. Una operación conserva su identidad al
/// actualizar el progreso; cada ejecución nueva genera una entrada distinta.
@MainActor
@Observable
final class ActivityLog {
    static let historyLimit = 200
    static var defaultStorageURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("work-buddy/Activity/history-v1.json")
    }

    enum Source: String, Codable {
        case manual, batch, autopilot
        var title: String {
            switch self {
            case .manual: L10n.text(.activityManual)
            case .batch: L10n.text(.activityBatch)
            case .autopilot: "Autopilot"
            }
        }
    }

    enum Status: Codable {
        case pending, checking, running, waiting(seconds: Int, attempt: Int)
        case succeeded, skipped(LocalizedMessage), failed(LocalizedMessage), uncertain(LocalizedMessage)

        var isComplete: Bool {
            switch self { case .succeeded, .skipped, .failed, .uncertain: true; default: false }
        }
        var isError: Bool { switch self { case .failed, .uncertain: true; default: false } }
        var needsVerification: Bool { if case .uncertain = self { true } else { false } }
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

    struct Entry: Codable, Identifiable {
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
        // Sigue activo durante una revalidación de una escritura incierta.
        private(set) var recoverAfterInterruption = false

        mutating func setStatus(_ status: Status) {
            self.status = status
            if status.isComplete {
                recoverAfterInterruption = status.needsVerification
            } else if case .running = status, action?.writesToGitHub == true {
                recoverAfterInterruption = true
            }
        }

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
    private let storageURL: URL?
    private let limit: Int
    private var canPersist = true

    private struct History: Codable {
        let version: Int
        let entries: [Entry]
        let unreadIDs: Set<UUID>
    }

    private struct Header: Decodable {
        let version: Int
    }

    /// Sin URL, los previews y tests mantienen su historial aislado en memoria.
    init(storageURL: URL? = nil, limit: Int = ActivityLog.historyLimit) {
        self.storageURL = storageURL
        self.limit = max(1, limit)
        guard let storageURL, FileManager.default.fileExists(atPath: storageURL.path) else { return }
        do {
            let data = try Data(contentsOf: storageURL)
            guard try JSONDecoder().decode(Header.self, from: data).version == 1 else {
                canPersist = false // No sobrescribir archivos de una versión futura.
                return
            }
            let history = try JSONDecoder().decode(History.self, from: data)
            entries = history.entries
            unreadIDs = history.unreadIDs
            for index in entries.indices where !entries[index].status.isComplete {
                let message = LocalizedMessage(L10n.text(.activityInterrupted))
                let status: Status = entries[index].recoverAfterInterruption ? .uncertain(message) : .skipped(message)
                entries[index].setStatus(status)
                unreadIDs.insert(entries[index].id)
            }
            prune()
            persist()
        } catch {
            debugLog("Could not load activity history: \(error)")
            // Apartar un archivo ilegible permite seguir guardando sin perder el original.
            let backup = storageURL.deletingPathExtension()
                .appendingPathExtension("unreadable-\(UUID().uuidString).json")
            do { try FileManager.default.moveItem(at: storageURL, to: backup) }
            catch { canPersist = false }
        }
    }

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
            entries[index].setStatus(status)
        } else {
            var entry = Entry(id: id, date: date, title: title, target: target, detail: detail,
                              url: url, symbol: symbol, source: source, status: status,
                              action: action, pullRequest: pullRequest, viewer: viewer)
            entry.setStatus(status)
            entries.insert(entry, at: 0)
        }
        if !isVisible { unreadIDs.insert(id) }
        prune()
        persist()
        return id
    }

    @discardableResult
    func record(_ action: PullRequestAction, on pr: PullRequest, status: Status = .succeeded, viewer: String? = nil) -> UUID {
        record(title: LocalizedMessage(action.title), target: "\(pr.repository) #\(pr.number)",
               detail: pr.title, url: pr.url, symbol: action.systemImage, status: status, action: action, pullRequest: pr, viewer: viewer)
    }

    func update(_ id: UUID, status: Status) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].setStatus(status)
        if !isVisible { unreadIDs.insert(id) }
        prune()
        persist()
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
        markVisibleAsRead()
    }

    func setPanelVisible(_ visible: Bool) {
        isPanelVisible = visible
        markVisibleAsRead()
    }

    private func markVisibleAsRead() {
        guard isVisible, !unreadIDs.isEmpty else { return }
        unreadIDs = []
        persist()
    }

    private func prune() {
        // Los resultados inciertos también impiden repetir escrituras: no vencen.
        entries = entries.enumerated().filter { index, entry in
            index < limit || !entry.status.isComplete || entry.status.needsVerification
        }.map(\.element)
        unreadIDs.formIntersection(Set(entries.map(\.id)))
    }

    private func persist() {
        guard let storageURL, canPersist else { return }
        do {
            let data = try JSONEncoder().encode(History(version: 1, entries: entries, unreadIDs: unreadIDs))
            try FileManager.default.createDirectory(at: storageURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            // Guardar antes de enviar una escritura; un cierre abrupto conserva su estado.
            try data.write(to: storageURL, options: .atomic)
        } catch {
            debugLog("Could not save activity history: \(error)")
        }
    }
}
