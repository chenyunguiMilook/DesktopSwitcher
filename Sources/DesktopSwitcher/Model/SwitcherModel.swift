import AppKit
import Observation

/// Observable state behind the widget: which desktops exist on the display the panel
/// currently sits on, and which one is active.
@Observable
@MainActor
final class SwitcherModel {

    /// Desktops of the display the panel is on. `nil` while SkyLight is unavailable.
    private(set) var display: DisplaySpaces?

    /// True whenever the process lacks Accessibility permission.
    ///
    /// Derived on every refresh rather than latched on a failed click, so granting
    /// permission while the widget is running clears the hint on its own.
    private(set) var needsAccessibility = !SpaceSwitcher.hasAccessibilityPermission

    /// False when the private read symbols could not be resolved at all.
    let isSupported = SkyLight.isAvailable

    /// The screen the panel sits on. Assigning re-reads immediately so dragging the
    /// widget across displays swaps the data source without waiting for the poll.
    var screen: NSScreen? {
        didSet {
            guard oldValue !== screen else { return }
            refresh()
        }
    }

    private var monitor: SpaceMonitor?

    init() {
        refresh()
        monitor = SpaceMonitor { [weak self] in self?.refresh() }
    }

    /// Re-reads topology and publishes only when something actually changed, so the
    /// background poll does not cause needless SwiftUI invalidation.
    func refresh() {
        // Cheap TCC lookup; picks up a grant made while the widget was already running.
        let lacksPermission = !SpaceSwitcher.hasAccessibilityPermission
        if lacksPermission != needsAccessibility {
            needsAccessibility = lacksPermission
        }

        guard isSupported else { return }
        let latest = SpaceReader.read(for: screen)
        guard latest != display else { return }
        display = latest
    }

    /// Removes the desktop at `index`, invoked from a pill's context menu.
    func remove(_ index: Int) {
        guard let display else { return }

        switch SpaceSwitcher.removeDesktop(at: index, on: display, screen: screen) {
        case .needsAccessibility:
            needsAccessibility = true
            SpaceSwitcher.requestAccessibilityPermission()
        case .switching:
            nudgeRefresh()
        case .alreadyThere, .invalidTarget:
            break
        }
    }

    /// Adds a desktop, invoked from the trailing "+" button.
    func addDesktop() {
        guard let display else { return }

        switch SpaceSwitcher.addDesktop(on: display, screen: screen) {
        case .needsAccessibility:
            needsAccessibility = true
            SpaceSwitcher.requestAccessibilityPermission()
        case .switching:
            nudgeRefresh()
        case .alreadyThere, .invalidTarget:
            break
        }
    }

    /// Adding and removing desktops post no notification, so re-read a few times while
    /// Mission Control settles.
    private func nudgeRefresh() {
        for delay in [0.6, 1.2, 1.8] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.refresh()
            }
        }
    }

    /// Handles a click on the desktop at `index`.
    func select(_ index: Int) {
        guard let display else { return }

        switch SpaceSwitcher.switch(to: index, on: display, screen: screen) {
        case .needsAccessibility:
            needsAccessibility = true
            SpaceSwitcher.requestAccessibilityPermission()
        case .switching:
            // The space-changed notification is the authoritative signal, but Mission
            // Control's animation means a nudge afterwards keeps the highlight tight if
            // the notification is missed.
            for delay in [0.5, 1.0] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    self?.refresh()
                }
            }
        case .alreadyThere, .invalidTarget:
            break
        }
    }

}
