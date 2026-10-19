import Foundation
import Testing
@testable import WorkBuddy

@Suite("Panel opening and responsiveness diagnostics")
@MainActor
struct PanelDiagnosticsTests {
    @Test("Measure opening phases and distinguish first opening from available snapshots")
    func opening() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = DiagnosticLog(directory: directory)
        var instant = SuspendingClock.now
        let panel = PanelDiagnostics(log: log, now: { instant })
        defer { panel.end() }
        panel.begin(hasSnapshot: false)
        let value = panel.measure(.panelRefresh) { instant += .milliseconds(2); return 42 }
        panel.measure(.panelLayout) { instant += .milliseconds(25) }
        panel.measure(.panelShow) { instant += .milliseconds(8); panel.shown() }
        panel.shown() // A duplicate callback does not record two openings.
        let open = try DiagnosticExport(await log.exportData())
        #expect(value == 42)
        #expect(open.text.contains("· in_progress"))
        #expect(open.records.first?.metadata?.service == .panel)
        #expect(open.records.contains { $0.metrics?["opening"] == 1 && $0.metrics?["hasSnapshot"] == 0 })
        for (phase, ms) in [(Diagnostics.Phase.panelRefresh, 2.0), (.panelLayout, 25.0), (.panelShow, 8.0), (.panelOpen, 35.0)] {
            let ended = open.records.filter { $0.phase == phase && $0.kind == .phaseEnded }
            #expect(ended.count == 1)
            #expect(abs((ended.first?.durationMs ?? -1) - ms) < 0.001)
        }
        panel.end()
        panel.end()
        panel.begin(hasSnapshot: true)
        panel.shown()
        panel.end()
        let closed = try DiagnosticExport(await log.exportData())
        #expect(closed.records.filter { $0.kind == .refreshEnded }.count == 2)
        #expect(closed.records.contains { $0.metrics?["opening"] == 2 && $0.metrics?["hasSnapshot"] == 1 })
    }

    @Test("Record delays of at least 100 ms and stop measuring on close")
    func mainThreadDelay() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = DiagnosticLog(directory: directory)
        var instant = SuspendingClock.now
        let panel = PanelDiagnostics(log: log, now: { instant })
        defer { panel.end() }
        panel.begin(hasSnapshot: true)
        panel.shown()
        for milliseconds in [250, 349, 350, 600, 250] {
            instant += .milliseconds(milliseconds)
            panel.probe()
        }
        panel.end()
        instant += .seconds(5)
        panel.probe()
        let exported = try DiagnosticExport(await log.exportData())
        let delays = exported.records.filter { $0.kind == .mainThreadDelayed }
        #expect(delays.count == 2)
        #expect(delays.map { Int(($0.durationMs ?? -1).rounded()) } == [100, 350])
        #expect(delays.allSatisfy { $0.phase == .panelResponsiveness })
        #expect(exported.records.contains { $0.metrics?["delays"] == 2 && $0.metrics?["maxDelayMs"] == 350 })
        #expect(exported.records.last?.kind == .refreshEnded)
    }

    @Test("Opening panels does not evict loads; reports include both histories")
    func separateRetention() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sync = DiagnosticLog(directory: directory, maxCycles: 3)
        let panels = DiagnosticLog(directory: directory.appendingPathComponent("Panels"), maxCycles: 2)
        for _ in 0..<3 { await Diagnostics.refresh(.github, log: sync) { } }
        let before = try DiagnosticExport(await sync.exportData())
        let panel = PanelDiagnostics(log: panels)
        defer { panel.end() }
        for _ in 0..<6 {
            panel.begin(hasSnapshot: true)
            panel.shown()
            panel.end()
        }
        let report = try DiagnosticExport(await DiagnosticLog.exportReport(sync: sync, panels: panels))
        let starts = report.records.filter { $0.kind == .refreshStarted }
        #expect(starts.filter { $0.metadata?.service == .github }.count == 3)
        #expect(starts.filter { $0.metadata?.service == .panel }.count == 2)
        #expect(Set(before.records.map(\.refresh)).isSubset(of: Set(report.records.map(\.refresh))))
        #expect(Set(report.records.compactMap { $0.metrics?["opening"] }) == [5, 6])
    }

    @Test("First exports and panel history failures do not prevent GitHub export")
    func missingAndFailedPanelStorage() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sync = DiagnosticLog(directory: directory)
        let empty = DiagnosticLog(directory: directory.appendingPathComponent("Panels"))
        await Diagnostics.refresh(.github, log: sync) { }
        let report = try DiagnosticExport(await DiagnosticLog.exportReport(sync: sync, panels: empty))
        #expect(report.records.filter { $0.kind == .refreshStarted }.count == 1)
        #expect(!report.text.contains("unavailable"))

        let blocker = directory.appendingPathComponent("PRIVATE-SENTINEL-file")
        try Data("fixture".utf8).write(to: blocker)
        let broken = DiagnosticLog(directory: blocker.appendingPathComponent("Panels"))
        let partial = try DiagnosticExport(await DiagnosticLog.exportReport(sync: sync, panels: broken))
        #expect(partial.records.count == report.records.count)
        #expect(partial.text.contains("Panel diagnostics unavailable"))
        #expect(!partial.text.contains("PRIVATE-SENTINEL"))
    }
}

private func temporaryDirectory() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("panel-diagnostics-\(UUID())")
}
