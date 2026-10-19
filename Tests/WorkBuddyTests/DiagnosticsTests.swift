import Foundation
import Testing

@testable import WorkBuddy

@Suite("Diagnóstico de sincronización")
struct DiagnosticsTests {
    @Test("Exporta una operación pendiente y distingue una sesión reabierta")
    func pendingRefreshAndReopening() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = DiagnosticLog(directory: directory)
        let gate = DiagnosticGate(expectedArrivals: 1)
        let task = Task {
            await Diagnostics.refresh(.github, log: log) {
                await Diagnostics.measure(.review) {
                    Diagnostics.record(.counts, metrics: [.items: 7])
                    await gate.suspend()
                }
            }
        }
        defer {
            task.cancel()
            Task { await gate.release() }
        }

        await gate.waitForArrivals()
        let pending = try DiagnosticExport(await log.exportData())
        let reopened = DiagnosticLog(directory: directory)
        let recovered = try DiagnosticExport(await reopened.exportData())
        await gate.release()
        await task.value
        let finished = try DiagnosticExport(await log.exportData())

        let refresh = try #require(pending.records.first?.refresh)
        #expect(pending.text.contains("Refresh \(refresh) · in_progress"))
        #expect(pending.records.contains { $0.kind == .phaseStarted && $0.phase == .review })
        #expect(!pending.records.contains { $0.kind == .phaseEnded || $0.kind == .refreshEnded })
        #expect(recovered.text.contains("Refresh \(refresh) · interrupted"))
        #expect(recovered.records.count == pending.records.count)
        #expect(finished.text.contains("Refresh \(refresh) · finished"))
        #expect(finished.records.filter { $0.kind == .refreshEnded }.count == 1)
        #expect(finished.records.contains { $0.kind == .phaseEnded && $0.durationMs != nil })
    }

    @Test("Conserva diez ciclos y un resultado tardío no recrea el expulsado")
    func retentionAndLateEvents() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = DiagnosticLog(directory: directory)
        let old = log.start(.github, forced: false)
        log.finish(old, cancelled: false)

        for index in 0..<12 {
            await Diagnostics.refresh(.jira, log: log) {
                Diagnostics.record(.counts, metrics: [.items: index])
            }
        }
        let retained = try DiagnosticExport(await log.exportData())
        log.record(.counts, context: old, metrics: [.items: 999])
        log.finish(old, cancelled: false)
        let afterLateEvents = try DiagnosticExport(await log.exportData())
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "jsonl" }

        #expect(files.count == 10)
        #expect(retained.records.filter { $0.kind == .refreshStarted }.count == 10)
        #expect(Set(retained.records.compactMap { $0.metrics?["items"] }) == Set(2..<12))
        #expect(afterLateEvents.records.count == retained.records.count)
        #expect(!afterLateEvents.records.contains { $0.refresh == old.refresh })
        #expect(!files.contains { $0.lastPathComponent.contains(old.refresh.uuidString) })
    }

    @Test("Un ciclo pendiente sobrevive a las actualizaciones terminadas del otro servicio")
    func pendingRefreshSurvivesRetention() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = DiagnosticLog(directory: directory)
        let pending = log.start(.github, forced: false)
        defer { log.finish(pending, cancelled: true) }

        for index in 0..<12 {
            await Diagnostics.refresh(.jira, log: log) {
                Diagnostics.record(.counts, metrics: [.items: index])
            }
        }
        log.record(.counts, context: pending, metrics: [.candidates: 99])
        let exported = try DiagnosticExport(await log.exportData())
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "jsonl" }

        #expect(files.count == 10)
        #expect(exported.records.filter { $0.kind == .refreshStarted }.count == 10)
        #expect(exported.text.contains("Refresh \(pending.refresh) · in_progress"))
        #expect(exported.records.contains { $0.refresh == pending.refresh && $0.metrics?["candidates"] == 99 })
        #expect(Set(exported.records.compactMap { $0.metrics?["items"] }) == Set(3..<12))

        log.finish(pending, cancelled: false)
        let finished = try DiagnosticExport(await log.exportData())
        #expect(finished.text.contains("Refresh \(pending.refresh) · finished"))
        #expect(finished.records.filter { $0.refresh == pending.refresh && $0.kind == .refreshEnded }.count == 1)
    }

    @Test("Si los ciclos activos exceden el límite, el expulsado no resucita con eventos tardíos")
    func evictedActiveRefreshDoesNotReturn() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = DiagnosticLog(directory: directory, maxCycles: 1)
        let old = log.start(.github, forced: false)
        let newer = log.start(.jira, forced: false)
        defer { log.finish(newer, cancelled: true) }
        let retained = try DiagnosticExport(await log.exportData())

        log.record(.counts, context: old, metrics: [.items: 999])
        log.finish(old, cancelled: false)
        let afterLateEvents = try DiagnosticExport(await log.exportData())
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "jsonl" }

        #expect(files.count == 1)
        #expect(Set(retained.records.map(\.refresh)) == [newer.refresh])
        #expect(afterLateEvents.records.count == retained.records.count)
        #expect(Set(afterLateEvents.records.map(\.refresh)) == [newer.refresh])
        #expect(afterLateEvents.text.contains("Refresh \(newer.refresh) · in_progress"))
        #expect(!files.contains { $0.lastPathComponent.contains(old.refresh.uuidString) })

        log.finish(newer, cancelled: false)
        let finished = try DiagnosticExport(await log.exportData())
        #expect(finished.text.contains("Refresh \(newer.refresh) · finished"))
    }

    @Test("El límite de bytes conserva JSON válido, truncamiento y finalización")
    func boundedCycle() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let byteLimit = 1_024
        let log = DiagnosticLog(directory: directory, maxBytesPerCycle: byteLimit)

        await Diagnostics.refresh(.github, log: log) {
            for index in 0..<100 {
                Diagnostics.record(.counts, phase: .replies, metrics: [.pages: index, .bytes: 8_192])
            }
        }
        let exported = try DiagnosticExport(await log.exportData())
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "jsonl" }
        #expect(files.count == 1)
        for file in files {
            #expect(try Data(contentsOf: file).count <= byteLimit)
        }
        #expect(exported.records.first?.kind == .refreshStarted)
        #expect(exported.records.filter { $0.kind == .truncated }.count == 1)
        #expect(exported.records.last?.kind == .refreshEnded)
        #expect(exported.records.filter { $0.kind == .counts }.count < 100)
    }

    @Test("Los contextos concurrentes y sus fases anidadas no mezclan métricas")
    func concurrentContexts() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = DiagnosticLog(directory: directory)
        let gate = DiagnosticGate(expectedArrivals: 2)
        let github = Task {
            await Diagnostics.refresh(.github, log: log) {
                await Diagnostics.measure(.review) {
                    async let request: Void = Diagnostics.measure(.gh) {
                        Diagnostics.record(.counts, metrics: [.bytes: 111])
                        await gate.suspend()
                    }
                    await request
                    Diagnostics.record(.counts, metrics: [.items: 11])
                }
            }
        }
        let jira = Task {
            await Diagnostics.refresh(.jira, log: log) {
                await Diagnostics.measure(.jiraPrimary) {
                    async let request: Void = Diagnostics.measure(.acli) {
                        Diagnostics.record(.counts, metrics: [.bytes: 222])
                        await gate.suspend()
                    }
                    await request
                    Diagnostics.record(.counts, metrics: [.items: 22])
                }
            }
        }
        defer {
            github.cancel()
            jira.cancel()
            Task { await gate.release() }
        }
        await gate.waitForArrivals()
        let pending = try DiagnosticExport(await log.exportData())
        await gate.release()
        await github.value
        await jira.value
        Diagnostics.record(.counts, metrics: [.items: 999])
        let finished = try DiagnosticExport(await log.exportData())

        #expect(pending.text.components(separatedBy: "· in_progress").count - 1 == 2)
        for (service, parentPhase, childPhase, itemCount, byteCount) in [
            (Diagnostics.Service.github, Diagnostics.Phase.review, Diagnostics.Phase.gh, 11, 111),
            (.jira, .jiraPrimary, .acli, 22, 222)
        ] {
            let start = try #require(finished.records.first { $0.metadata?.service == service })
            let records = finished.records.filter { $0.refresh == start.refresh }
            let parent = try #require(records.first { $0.kind == .phaseStarted && $0.phase == parentPhase })
            let child = try #require(records.first { $0.kind == .phaseStarted && $0.phase == childPhase })
            #expect(parent.span != nil)
            #expect(child.parent == parent.span)
            #expect(Set(records.compactMap { $0.metrics?["items"] }) == [itemCount])
            #expect(Set(records.compactMap { $0.metrics?["bytes"] }) == [byteCount])
            #expect(records.first { $0.metrics?["items"] != nil }?.phase == parentPhase)
            #expect(records.first { $0.metrics?["bytes"] != nil }?.phase == childPhase)
            #expect(records.filter { $0.kind == .refreshEnded }.count == 1)
        }
    }

    @Test("Los errores exportan categorías y códigos sin sus datos privados")
    func errorPrivacy() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = DiagnosticLog(directory: directory)
        let sentinel = "PRIVATE-SENTINEL-token-repository-user"
        let failures: [any Error] = [
            GH.Failure.commandFailed(exitCode: 23, stderr: "HTTP 502 \(sentinel)"),
            GH.Failure.commandFailed(exitCode: 1, stderr: "API rate limit exceeded \(sentinel)"),
            GH.Failure.badJSON("GraphQL: secondary rate limit \(sentinel)"),
            GH.Failure.notAuthenticated(sentinel),
            GH.Failure.badJSON(sentinel),
            GH.Failure.missingThreads(sentinel),
            ACLI.Failure.commandFailed(exitCode: 17, output: "HTTP 403 \(sentinel)"),
            ACLI.Failure.badJSON(sentinel),
            JiraQueue.QueryFailure(title: "PRIVATE-SENTINEL-token-repository-user", exitCode: 17, output: "HTTP 403 \(sentinel)"),
            NSError(domain: sentinel, code: 88, userInfo: [NSLocalizedDescriptionKey: sentinel])
        ]

        await Diagnostics.refresh(.github, log: log) {
            for failure in failures {
                do {
                    try await Diagnostics.measure(.gh) { () async throws -> Void in throw failure }
                    Issue.record("La instrumentación no debe absorber el error del loader")
                } catch {
                    Diagnostics.record(.failed, error: error)
                }
            }
        }
        let exported = try DiagnosticExport(await log.exportData())
        #expect(!exported.text.contains(sentinel))
        #expect(Set(exported.records.compactMap { $0.failure?.category }) == [
            "http_502", "rate_limited", "not_authenticated", "invalid_response", "http_403", "other"
        ])
        #expect(Set(exported.records.compactMap { $0.failure?.exitCode }) == [1, 17, 23])
        #expect(exported.records.filter { $0.kind == .phaseEnded && $0.failure != nil }.count == failures.count)
    }

    @Test("Una falla del almacenamiento no altera el resultado del loader")
    func unavailableStorage() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let blocker = directory.appendingPathComponent("not-a-directory")
        try Data("fixture".utf8).write(to: blocker)
        let log = DiagnosticLog(directory: blocker.appendingPathComponent("diagnostics"))
        let executions = DiagnosticExecutions()

        await Diagnostics.refresh(.github, log: log) {
            let result = await Diagnostics.measure(.review) {
                await executions.record()
                return 42
            }
            #expect(result == 42)
            do {
                try await Diagnostics.measure(.merge) { () async throws -> Void in
                    throw DiagnosticFixtureFailure.expected
                }
                Issue.record("El error original debe conservarse aunque el log no pueda escribirse")
            } catch {
                #expect(error as? DiagnosticFixtureFailure == .expected)
            }
        }
        #expect(await executions.count == 1)
        await #expect(throws: (any Error).self) { _ = try await log.exportData() }
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("work-buddy-diagnostics-tests-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

struct DiagnosticExport {
    struct Record: Decodable {
        struct Metadata: Decodable { let service: Diagnostics.Service }
        struct Failure: Decodable { let category: String; let exitCode: Int32? }

        let kind: Diagnostics.Kind
        let refresh: UUID
        let span: UUID?
        let parent: UUID?
        let phase: Diagnostics.Phase?
        let durationMs: Double?
        let metrics: [String: Int]?
        let failure: Failure?
        let metadata: Metadata?
    }

    let text: String
    let records: [Record]

    init(_ data: Data) throws {
        text = String(decoding: data, as: UTF8.self)
        records = try text.split(separator: "\n").filter { $0.hasPrefix("{") }.map {
            try JSONDecoder().decode(Record.self, from: Data($0.utf8))
        }
    }
}

private actor DiagnosticGate {
    private let expectedArrivals: Int
    private var arrivals = 0
    private var observer: CheckedContinuation<Void, Never>?
    private var pending: [CheckedContinuation<Void, Never>] = []
    private var isReleased = false

    init(expectedArrivals: Int) { self.expectedArrivals = expectedArrivals }

    func suspend() async {
        arrivals += 1
        if arrivals == expectedArrivals {
            observer?.resume()
            observer = nil
        }
        guard !isReleased else { return }
        await withCheckedContinuation { pending.append($0) }
    }

    func waitForArrivals() async {
        guard arrivals < expectedArrivals else { return }
        await withCheckedContinuation { observer = $0 }
    }

    func release() {
        isReleased = true
        pending.forEach { $0.resume() }
        pending = []
    }
}

private actor DiagnosticExecutions {
    private(set) var count = 0
    func record() { count += 1 }
}

private enum DiagnosticFixtureFailure: Error { case expected }
