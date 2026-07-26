import AppKit

/// Fades the panel back after a spell of inactivity, and brings it forward again only when
/// the pointer *rests* on it.
///
/// Waking on plain mouse-entered would light the widget up every time the pointer crossed
/// it on the way somewhere else, which is what makes this kind of overlay distracting. So
/// the pointer has to dwell; passing straight over changes nothing. Clicking wakes
/// immediately — at that point the intent is not in doubt.
///
/// Hover state comes from polling the real cursor position, not from tracking-area
/// enter/exit events. Those proved unreliable: reinstalling the tracking area on layout
/// emits a spurious exit/enter pair, and one bogus "entered" with no matching "exited"
/// latched the widget awake for good. A cursor-position read cannot fall out of sync, so
/// this state machine is self-correcting — and it leaves SwiftUI's own tracking areas, which
/// drive the per-pill hover highlight, untouched.
@MainActor
final class IdleFader {

    /// Recessed enough to stop competing for attention, still legible enough to answer
    /// "which desktop am I on?" at a glance — the main reason to keep it on screen.
    private let fadedAlpha: CGFloat = 0.4

    /// Quiet time before receding.
    private let idleDelay: TimeInterval = 4.0

    /// How long the pointer must rest on the widget to wake it.
    private let dwellDelay: TimeInterval = 0.5

    /// Slow out, quick in: receding should go unnoticed, waking should feel immediate.
    private let fadeOutDuration: TimeInterval = 0.6
    private let fadeInDuration: TimeInterval = 0.15

    /// Fine enough to time a 0.5s dwell, coarse enough to stay invisible in CPU terms —
    /// one cheap cursor-position read per tick.
    private let tickInterval: TimeInterval = 0.2

    private weak var panel: NSPanel?

    /// Touched from `deinit`, which is nonisolated; only ever written on the main actor.
    private nonisolated(unsafe) var ticker: Timer?

    private var isFaded = false
    private var lastActivity = Date()
    private var dwellStartedAt: Date?

    init(panel: NSPanel) {
        self.panel = panel
        panel.alphaValue = 1

        let timer = Timer(timeInterval: tickInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        // .common so it keeps running through a window drag's event tracking loop.
        RunLoop.main.add(timer, forMode: .common)
        ticker = timer
    }

    deinit {
        ticker?.invalidate()
    }

    /// A click, drag or menu is unambiguous intent: wake now and restart the idle clock.
    func noteInteraction() {
        lastActivity = Date()
        dwellStartedAt = nil
        wake()
    }

    // MARK: - State machine

    private func tick() {
        let now = Date()

        guard pointerIsInside else {
            dwellStartedAt = nil
            if !isFaded, now.timeIntervalSince(lastActivity) > idleDelay {
                fade()
            }
            return
        }

        // Resting on the widget: never let it recede from under the pointer.
        lastActivity = now

        guard isFaded else {
            dwellStartedAt = nil
            return
        }

        if let started = dwellStartedAt {
            if now.timeIntervalSince(started) >= dwellDelay { wake() }
        } else {
            dwellStartedAt = now
        }
    }

    /// The single source of truth for hover state.
    private var pointerIsInside: Bool {
        guard let panel, panel.isVisible else { return false }
        return panel.frame.contains(NSEvent.mouseLocation)
    }

    // MARK: - Alpha

    private func wake() {
        guard isFaded else { return }
        isFaded = false
        dwellStartedAt = nil
        animateAlpha(to: 1, duration: fadeInDuration)
    }

    private func fade() {
        guard !isFaded else { return }
        isFaded = true
        animateAlpha(to: fadedAlpha, duration: fadeOutDuration)
    }

    private func animateAlpha(to target: CGFloat, duration: TimeInterval) {
        guard let panel else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.animator().alphaValue = target
        }
    }
}
