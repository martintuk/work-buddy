import Foundation

/// Sólo valores enumerados y cantidades: nunca argumentos, respuestas ni errores crudos.
enum Diagnostics {
    enum Service: String, Codable, Sendable { case github, jira }
    enum Phase: String, Codable, Sendable {
        case preflight, viewer, review, merge, own, conversationCandidates, replies
        case dependabot, teamDependabot, ownership, teamSearch, behind, notifications
        case gh, jiraAuth, jiraSHR, jiraRecent, acli
    }
    enum Kind: String, Codable, Sendable {
        case refreshStarted, refreshEnded, cancelled, failed, phaseStarted, phaseEnded
        case published, firstContent, queuesLoaded, counts, retry
        case cacheHit, cacheMiss, cacheFallback, disabled, signedOut, unavailable, partial, truncated
    }
    enum Metric: String, Sendable {
        case items, candidates, batchSize, pages, bytes, attempt, repositories, teams, ageSeconds, forced
    }

    struct Failure: Codable, Sendable {
        let category: String
        var exitCode: Int32?

        init(_ error: Error) {
            switch error {
            case is CancellationError: category = "cancelled"
            case GH.Failure.notInstalled, ACLI.Failure.notInstalled: category = "not_installed"
            case GH.Failure.notAuthenticated, ACLI.Failure.notAuthenticated: category = "not_authenticated"
            case GH.Failure.commandFailed(let code, let detail),
                 ACLI.Failure.commandFailed(let code, let detail):
                exitCode = code
                if let status = [401, 403, 429, 500, 502, 503, 504].first(where: {
                    detail.localizedCaseInsensitiveContains("HTTP \($0)")
                }) {
                    category = "http_\(status)"
                } else if detail.localizedCaseInsensitiveContains("timeout") {
                    category = "timeout"
                } else if detail.localizedCaseInsensitiveContains("connection reset") {
                    category = "connection_reset"
                } else {
                    category = "command_failed"
                }
            case is GH.Failure, is ACLI.Failure: category = "invalid_response"
            default: category = "other"
            }
        }
    }

    struct Context: Sendable {
        let log: DiagnosticLog
        let refresh: UUID
        let started: ContinuousClock.Instant
        var span: UUID?
        var phase: Phase?
    }

    @TaskLocal static var context: Context?

    static func refresh(
        _ service: Service, forced: Bool = false, log: DiagnosticLog = .shared,
        isolation: isolated (any Actor)? = #isolation,
        operation: () async -> Void
    ) async {
        let context = log.start(service, forced: forced)
        await $context.withValue(context) { await operation() }
        log.finish(context, cancelled: Task.isCancelled)
    }

    static func measure<T: Sendable>(
        _ phase: Phase, isolation: isolated (any Actor)? = #isolation,
        operation: () async throws -> T
    ) async rethrows -> T {
        guard var child = context else { return try await operation() }
        let parent = child.span
        child.span = UUID()
        child.phase = phase
        let start = ContinuousClock.now
        child.log.record(.phaseStarted, context: child, parent: parent)
        do {
            let result = try await $context.withValue(child) { try await operation() }
            child.log.record(.phaseEnded, context: child, duration: milliseconds(start.duration(to: .now)))
            return result
        } catch {
            child.log.record(.phaseEnded, context: child, duration: milliseconds(start.duration(to: .now)),
                             failure: Failure(error))
            throw error
        }
    }

    static func record(_ kind: Kind, phase: Phase? = nil, metrics: [Metric: Int] = [:], error: Error? = nil) {
        guard var context else { return }
        if let phase { context.phase = phase }
        context.log.record(kind, context: context, metrics: metrics, failure: error.map(Failure.init))
    }

    private static func milliseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1_000 + Double(duration.components.attoseconds) / 1e15
    }

    static func elapsed(_ context: Context) -> Double { milliseconds(context.started.duration(to: .now)) }
}

/// El estado y los archivos viven únicamente en `queue`. Encolar no suspende al
/// store ni escribe desde el hilo de UI. Exportar espera las escrituras encoladas.
final class DiagnosticLog: @unchecked Sendable {
    static let shared = DiagnosticLog(directory: FileManager.default.urls(
        for: .applicationSupportDirectory, in: .userDomainMask
    )[0].appendingPathComponent("work-buddy/Diagnostics", isDirectory: true))

    private struct Metadata: Codable, Sendable {
        var schema = 1
        let session: UUID
        let service: Diagnostics.Service
        let startedAt: Date
        let version: String
        let revision: String
        let os: String
    }

    private struct Entry: Codable, Sendable {
        let kind: Diagnostics.Kind
        let refresh: UUID
        var elapsedMs: Double = 0
        var span: UUID?
        var parent: UUID?
        var phase: Diagnostics.Phase?
        var durationMs: Double?
        var metrics: [String: Int]?
        var failure: Diagnostics.Failure?
        var metadata: Metadata?
    }

    private struct OpenFile {
        let url: URL
        let handle: FileHandle
        let started: ContinuousClock.Instant
        var bytes = 0
        var truncated = false
    }

    private let queue = DispatchQueue(label: "work-buddy.diagnostics", qos: .utility)
    private let directory: URL
    private let maxCycles: Int
    private let maxBytesPerCycle: Int
    private let session = UUID()
    private var openFiles: [UUID: OpenFile] = [:]
    private var writeFailures = 0

    init(directory: URL, maxCycles: Int = 10, maxBytesPerCycle: Int = 131_072) {
        self.directory = directory
        self.maxCycles = max(1, maxCycles)
        self.maxBytesPerCycle = max(1_024, maxBytesPerCycle)
    }

    func start(_ service: Diagnostics.Service, forced: Bool) -> Diagnostics.Context {
        let context = Diagnostics.Context(log: self, refresh: UUID(), started: .now)
        let now = Date()
        let metadata = Metadata(
            session: session, service: service, startedAt: now,
            version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev",
            revision: Bundle.main.object(forInfoDictionaryKey: "WorkBuddyRevision") as? String ?? "unknown",
            os: ProcessInfo.processInfo.operatingSystemVersionString
        )
        queue.async { [self] in
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let name = String(format: "%020.6f", now.timeIntervalSince1970) + "-\(context.refresh).jsonl"
                let url = directory.appendingPathComponent(name)
                guard FileManager.default.createFile(atPath: url.path, contents: nil,
                                                     attributes: [.posixPermissions: 0o600]) else {
                    throw CocoaError(.fileWriteUnknown)
                }
                openFiles[context.refresh] = OpenFile(url: url, handle: try FileHandle(forWritingTo: url),
                                                     started: context.started)
                append(Entry(kind: .refreshStarted, refresh: context.refresh,
                             metrics: ["forced": forced ? 1 : 0], metadata: metadata))
                // Una consulta colgada debe sobrevivir al polling del otro
                // servicio. Si hay más de diez activas, igual respetamos el tope.
                // Los nombres son UUIDs únicos dentro del mismo directorio.
                // No comparar URLs: Foundation puede resolver /var a /private/var al listar.
                let active = Set(openFiles.values.map { $0.url.lastPathComponent })
                let obsolete = try files().sorted {
                    if active.contains($0.lastPathComponent) != active.contains($1.lastPathComponent) {
                        return !active.contains($0.lastPathComponent)
                    }
                    return $0.lastPathComponent < $1.lastPathComponent
                }.dropLast(maxCycles)
                for old in obsolete {
                    if let id = openFiles.first(where: { $0.value.url.lastPathComponent == old.lastPathComponent })?.key {
                        try? openFiles.removeValue(forKey: id)?.handle.close()
                    }
                    try FileManager.default.removeItem(at: old)
                }
            } catch { writeFailures += 1 }
        }
        return context
    }

    func record(_ kind: Diagnostics.Kind, context: Diagnostics.Context, parent: UUID? = nil,
                duration: Double? = nil, metrics: [Diagnostics.Metric: Int] = [:],
                failure: Diagnostics.Failure? = nil) {
        let entry = Entry(kind: kind, refresh: context.refresh, elapsedMs: Diagnostics.elapsed(context),
                          span: context.span, parent: parent, phase: context.phase, durationMs: duration,
                          metrics: metrics.isEmpty ? nil : Dictionary(uniqueKeysWithValues: metrics.map { ($0.key.rawValue, $0.value) }),
                          failure: failure)
        queue.async { [self] in append(entry) }
    }

    func finish(_ context: Diagnostics.Context, cancelled: Bool) {
        let entry = Entry(kind: cancelled ? .cancelled : .refreshEnded, refresh: context.refresh,
                          elapsedMs: Diagnostics.elapsed(context))
        queue.async { [self] in
            append(entry, final: true)
            try? openFiles.removeValue(forKey: context.refresh)?.handle.close()
        }
    }

    private func append(_ entry: Entry, final: Bool = false) {
        guard var file = openFiles[entry.refresh], !file.truncated || final else { return }
        do {
            var data = try encode(entry)
            // Reserva espacio para indicar truncamiento y el fin del ciclo.
            if !final, file.bytes + data.count > maxBytesPerCycle - 512 {
                data = try encode(Entry(kind: .truncated, refresh: entry.refresh, elapsedMs: entry.elapsedMs))
                file.truncated = true
            }
            guard file.bytes + data.count <= maxBytesPerCycle else { return }
            try file.handle.write(contentsOf: data)
            file.bytes += data.count
            openFiles[entry.refresh] = file
        } catch { writeFailures += 1 }
    }

    private func files() throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "jsonl" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(value)
        data.append(10)
        return data
    }

    /// Un encabezado distingue ciclos actuales pendientes de procesos anteriores
    /// interrumpidos. Los registros originales quedan intactos al volver a abrir.
    func exportData() async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                do {
                    var data = Data("Work Buddy diagnostic · schema 1\nExported: \(Date().ISO8601Format())\nStorage errors: \(writeFailures)\n".utf8)
                    for url in try files().suffix(maxCycles) {
                        let handle = try FileHandle(forReadingFrom: url)
                        let contents = try handle.read(upToCount: maxBytesPerCycle) ?? Data()
                        try handle.close()
                        let decoder = JSONDecoder()
                        decoder.dateDecodingStrategy = .iso8601
                        let entries = contents.split(separator: 10).compactMap { try? decoder.decode(Entry.self, from: Data($0)) }
                        guard let first = entries.first else { continue }
                        let ended = entries.contains { $0.kind == .refreshEnded || $0.kind == .cancelled }
                        let status = ended ? "finished" : (openFiles[first.refresh] == nil ? "interrupted" : "in_progress")
                        var summary = "\nRefresh \(first.refresh) · \(status)"
                        if let file = openFiles[first.refresh] {
                            let context = Diagnostics.Context(log: self, refresh: first.refresh, started: file.started)
                            summary += " · elapsed_ms=\(Int(Diagnostics.elapsed(context)))"
                        }
                        data.append(Data((summary + "\n").utf8))
                        data.append(contents)
                    }
                    continuation.resume(returning: data)
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
}
