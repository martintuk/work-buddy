import Foundation

/// Local measurements while the panel is open. The timer observes run-loop
/// delays, not rendered frames or the exact duration of every stall.
@MainActor
final class PanelDiagnostics {
    private let log: DiagnosticLog
    private let now: () -> SuspendingClock.Instant
    private var context: Diagnostics.Context?
    private var opening: (context: Diagnostics.Context, started: SuspendingClock.Instant)?
    private var lastProbe: SuspendingClock.Instant?
    private var timer: Timer?
    private var openingCount = 0
    private var delays = 0
    private var maxDelay = 0.0
    private static let probeInterval = 0.25

    init(log: DiagnosticLog = .panels, now: @escaping () -> SuspendingClock.Instant = { .now }) {
        self.log = log
        self.now = now
    }

    func begin(hasSnapshot: Bool) {
        end()
        openingCount += 1
        delays = 0
        maxDelay = 0
        let root = log.start(.panel, forced: false)
        context = root
        var open = root
        open.phase = .panelOpen
        open.span = UUID()
        opening = (open, now())
        log.record(.phaseStarted, context: open, metrics: [.opening: openingCount, .hasSnapshot: hasSnapshot ? 1 : 0])
        lastProbe = now()
        let timer = Timer(timeInterval: Self.probeInterval, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            // Registered only on the main run loop, including tracking modes.
            MainActor.assumeIsolated {
                self.probe()
            }
        }
        timer.tolerance = 0.025
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func measure<T>(_ phase: Diagnostics.Phase, operation: () -> T) -> T {
        guard var span = context else { return operation() }
        span.phase = phase
        span.span = UUID()
        let started = now()
        log.record(.phaseStarted, context: span)
        let result = operation()
        log.record(.phaseEnded, context: span, duration: Diagnostics.milliseconds(started.duration(to: now())))
        return result
    }

    /// AppKit reported the popover shown; this is not the compositor's first frame.
    func shown() {
        guard let opening else { return }
        log.record(.phaseEnded, context: opening.context,
                   duration: Diagnostics.milliseconds(opening.started.duration(to: now())))
        self.opening = nil
    }

    func probe() {
        guard var context, let previous = lastProbe else { return }
        let current = now()
        lastProbe = current
        // SuspendingClock excludes time while the machine sleeps.
        let delay = Diagnostics.milliseconds(previous.duration(to: current)) - Self.probeInterval * 1_000
        guard delay >= 100 else { return }
        delays += 1
        maxDelay = max(maxDelay, delay)
        context.phase = .panelResponsiveness
        log.record(.mainThreadDelayed, context: context, duration: delay)
    }

    func end() {
        timer?.invalidate()
        timer = nil
        guard var context else { return }
        context.phase = .panelResponsiveness
        log.record(.counts, context: context, metrics: [.delays: delays, .maxDelayMs: Int(maxDelay.rounded())])
        log.finish(context, cancelled: opening != nil)
        self.context = nil
        opening = nil
        lastProbe = nil
    }
}
