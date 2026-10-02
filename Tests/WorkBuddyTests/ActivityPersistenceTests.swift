import Foundation
import Testing
@testable import WorkBuddy

@Suite("Persistencia de actividad")
@MainActor
struct ActivityPersistenceTests {
    @Test("Un nuevo store restaura acciones manuales, lotes y autopilot con sus datos y traducciones")
    func roundTrip() throws {
        let url = temporaryURL()
        defer { removeDirectory(url) }
        let log = ActivityLog(storageURL: url)
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let manual = log.record(title: LocalizedMessage(L10n.text(.editorOpen)), target: "org/café #1",
            detail: "Proyecto con Unicode y 100%", url: fixture(1).url, symbol: "terminal", date: date)
        log.record(PullRequestBatch.Entry(candidate: .init(pullRequest: fixture(2), action: .approve),
                   status: .completed(.approve)), source: .batch, viewer: "me")
        log.record(PullRequestBatch.Entry(candidate: .init(pullRequest: fixture(3), action: .merge),
                   status: .failed(LocalizedMessage("GitHub unavailable"))), source: .autopilot, viewer: "me")
        let skipped = log.record(.approve, on: fixture(4),
            status: .skipped(LocalizedMessage(L10n.text(.batchChanged))), viewer: "me")
        let language = Localization.shared.language
        let restored = ActivityLog(storageURL: url)
        #expect(restored.entries.map(\.id) == log.entries.map(\.id))
        #expect(restored.entries.map(\.source) == [.manual, .autopilot, .batch, .manual])
        #expect(restored.unreadIDs == log.unreadIDs)
        let entry = try #require(restored.entries.first { $0.id == manual })
        #expect(entry.date == date && entry.target == "org/café #1")
        #expect(entry.detail == "Proyecto con Unicode y 100%" && entry.url == fixture(1).url)
        #expect(entry.symbol == "terminal")
        let approved = try #require(restored.entries.first { $0.source == .batch })
        #expect(approved.action == .approve && approved.pullRequest?.headRefOID == fixture(2).headRefOID)
        #expect(approved.pullRequest?.author.isDependabot == true && approved.viewer == "me")
        for selected in [AppLanguage.spanish, .english] {
            L10n.$renderLanguage.withValue(selected) {
                #expect(entry.title.text == L10n.text(.editorOpen))
                #expect(approved.statusText == L10n.text(.prApproved))
                #expect(restored.entries.first { $0.id == skipped }?.status.text == L10n.text(.batchChanged))
            }
        }
        #expect(Localization.shared.language == language)
    }

    @Test("Los resultados actualizados y las novedades leídas sobreviven a otro reinicio")
    func updatesAndReadState() {
        let url = temporaryURL()
        defer { removeDirectory(url) }
        let log = ActivityLog(storageURL: url)
        let id = log.record(.merge, on: fixture(1), status: .running, viewer: "me")
        log.update(id, status: .succeeded)
        let restored = ActivityLog(storageURL: url)
        #expect(restored.entries.count == 1 && restored.unreadIDs == [id])
        #expect(restored.entries.first?.statusText == L10n.text(.prMerged))
        restored.setPanelVisible(false)
        restored.setVisible(true)
        #expect(ActivityLog(storageURL: url).unreadIDs == [id])
        restored.setPanelVisible(true)
        #expect(ActivityLog(storageURL: url).unreadIDs.isEmpty)
        restored.setVisible(false)
        restored.update(id, status: .failed(LocalizedMessage("Late error")))
        #expect(ActivityLog(storageURL: url).hasUnreadErrors)
    }

    @Test("Un reinicio cierra los pendientes y conserva escrituras y verificaciones interrumpidas como inciertas")
    func interruptedOperations() {
        let url = temporaryURL()
        defer { removeDirectory(url) }
        let log = ActivityLog(storageURL: url)
        let pending = log.record(.approve, on: fixture(1), status: .pending, viewer: "me")
        let checking = log.record(.approve, on: fixture(2), status: .checking, viewer: "me")
        let waiting = log.record(.approve, on: fixture(3), status: .waiting(seconds: 2, attempt: 1), viewer: "me")
        let sent = log.record(.merge, on: fixture(4), status: .running, viewer: "me")
        let verifying = log.record(.approve, on: fixture(5), status: .uncertain(LocalizedMessage("Unknown")), viewer: "me")
        log.update(verifying, status: .checking)
        let retrying = log.record(.approve, on: fixture(6), status: .running, viewer: "me")
        log.update(retrying, status: .waiting(seconds: 5, attempt: 2))
        let local = log.record(title: LocalizedMessage("Editor"), target: "org/api #7", symbol: "terminal", status: .running)
        log.setVisible(true)
        let restored = ActivityLog(storageURL: url)
        #expect(restored.entries.allSatisfy { $0.status.isComplete })
        #expect(restored.runningCount == 0 && restored.pendingCount == 0)
        for id in [pending, checking, waiting, local] {
            #expect(restored.entries.first { $0.id == id }?.status.text == L10n.text(.activityInterrupted))
            #expect(restored.entries.first { $0.id == id }?.status.needsVerification == false)
        }
        for id in [sent, verifying, retrying] {
            #expect(restored.entries.first { $0.id == id }?.status.needsVerification == true)
            #expect(restored.unreadIDs.contains(id))
        }
        #expect(restored.needsVerification(for: fixture(4), viewer: "me"))
        #expect(!restored.needsVerification(for: fixture(4, head: "new"), viewer: "me"))
        #expect(!restored.needsVerification(for: fixture(4), viewer: "other"))
        #expect(ActivityLog(storageURL: url).entries.count { $0.status.needsVerification } == 3)
    }

    @Test("Retiene las últimas 50 actividades, en el orden del historial")
    func defaultRetention() {
        let log = ActivityLog()
        for number in 0..<90 {
            log.record(title: LocalizedMessage("Open"), target: String(number), symbol: "link")
        }
        #expect(log.entries.count == 50 && log.unreadIDs.count == 50)
        #expect(log.entries.first?.target == "89" && log.entries.last?.target == "40")
    }

    @Test("La retención en disco protege operaciones activas e inciertas y poda al resolverlas")
    func protectedRetention() {
        let url = temporaryURL()
        defer { removeDirectory(url) }
        let log = ActivityLog(storageURL: url, limit: 3)
        let uncertain = log.record(.merge, on: fixture(1), status: .uncertain(LocalizedMessage("Unknown")), viewer: "me")
        let running = log.record(.approve, on: fixture(2), status: .running, viewer: "me")
        for number in 3...9 { log.record(.approve, on: fixture(number)) }
        #expect(log.entries.count == 5 && log.unreadIDs.count == 5)
        log.update(running, status: .succeeded)
        #expect(log.entries.count == 4)
        let restored = ActivityLog(storageURL: url, limit: 3)
        #expect(restored.entries.map(\.target) == ["org/api #9", "org/api #8", "org/api #7", "org/api #1"])
        #expect(restored.needsVerification(for: fixture(1), viewer: "me"))
        restored.update(uncertain, status: .succeeded)
        #expect(restored.entries.count == 3 && !restored.unreadIDs.contains(uncertain))
        #expect(ActivityLog(storageURL: url, limit: 3).entries.count == 3)
    }

    @Test("El store puede verificar una escritura incierta recuperada del disco sin enviarla de nuevo")
    func verificationAfterRestart() async throws {
        let url = temporaryURL()
        defer { removeDirectory(url) }
        let pr = fixture(1)
        let id = ActivityLog(storageURL: url).record(.approve, on: pr, status: .running, viewer: "me")
        let store = ReviewQueueStore.preview(reviews: [pr], merges: [], activity: ActivityLog(storageURL: url))
        #expect(store.actionToVerify(for: pr)?.id == id)
        #expect(store.batchCandidates.isEmpty && store.availableWriteActions(for: pr).isEmpty)
        await store.verifyAction(id) { pr, viewer, _ in
            var approved = pr
            approved.approvedByMe = true
            return .init(viewer: viewer, pullRequest: approved, isOpen: true)
        }
        let restored = ActivityLog(storageURL: url)
        #expect(restored.entries.first?.statusText == L10n.text(.prApproved))
        #expect(!restored.needsVerification(for: pr, viewer: "me"))
    }

    @Test("Un archivo corrupto se conserva aparte y el historial vuelve a guardar")
    func corruptFile() throws {
        let url = temporaryURL()
        defer { removeDirectory(url) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let original = Data("incomplete JSON".utf8)
        try original.write(to: url)
        let log = ActivityLog(storageURL: url)
        #expect(log.entries.isEmpty)
        let backup = try #require(FileManager.default.contentsOfDirectory(at: url.deletingLastPathComponent(),
            includingPropertiesForKeys: nil).first { $0.lastPathComponent.contains("unreadable") })
        #expect(try Data(contentsOf: backup) == original)
        log.record(.approve, on: fixture(1))
        #expect(ActivityLog(storageURL: url).entries.count == 1)
    }

    @Test("Una versión futura se conserva sin sobrescribirla")
    func futureVersion() throws {
        let url = temporaryURL()
        defer { removeDirectory(url) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let original = Data("{\"version\":2,\"newFormat\":{}}".utf8)
        try original.write(to: url)
        let log = ActivityLog(storageURL: url)
        log.record(.approve, on: fixture(1))
        #expect(try Data(contentsOf: url) == original)
    }

    private func temporaryURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("work-buddy-activity-\(UUID().uuidString)")
            .appendingPathComponent("history.json")
    }

    private func removeDirectory(_ url: URL) {
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }
}
