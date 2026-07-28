import AppKit
import ApplicationServices

/// Drives Mission Control's Spaces bar through the Accessibility API to switch, add and
/// remove desktops.
///
/// ## Why this route
///
/// Two more direct approaches are dead on macOS 26:
///
/// * **Private CGS/SkyLight writes.** `CGSManagedDisplaySetCurrentSpace`, its transaction
///   form, show/hide pairs and window-parking all report success while leaving the
///   rendered display byte-identical — they only update WindowServer bookkeeping, which
///   then disagrees with what is on screen. `Tools/cgs-probe.swift` measures all nine.
/// * **Synthetic ⌃←/⌃→ keystrokes.** WindowServer's `CGXSenderCanSynthesizeEvents` filter
///   drops `CGEventPost` events before the hotkey matcher. Measured: the events do reach
///   the HID stream and a plain keystroke still lands in a focused text field, yet no
///   system chord fires — not Mission Control, not even ⌘Space for Spotlight.
///
/// What does work is an Accessibility *action*, a direct message to the Dock rather than a
/// synthesized event, so the filter does not apply. Mission Control is a real app bundle,
/// so opening it needs no event synthesis either.
///
/// ## Why the retry loop
///
/// The Dock ignores a tile press that arrives before Mission Control is ready, and there
/// is no geometric signal for readiness: the tiles appear at a fixed off-screen position
/// (`(798, -32)`, `37×24`) and never move, because the Spaces bar is collapsed. Sampling
/// their position therefore tells you nothing — an earlier version waited for the position
/// to "settle" and pressed ~37ms in, which failed intermittently. Worse, a swallowed press
/// still closes Mission Control, so a naive retry finds no tiles and gives up.
///
/// The only trustworthy readiness signal is whether the action took effect, so switching
/// presses, verifies against `SLSGetActiveSpace`, and presses again — reopening Mission
/// Control if a swallowed press closed it.
enum SpaceSwitcher {

    enum Outcome: Equatable {
        /// The action is under way; completion is asynchronous.
        case switching
        /// Already on the requested desktop.
        case alreadyThere
        /// Accessibility permission is missing; nothing was done.
        case needsAccessibility
        /// The target does not exist.
        case invalidTarget
    }

    /// The desktop tiles are the only AX elements offering this action, which makes it a
    /// language-independent way to find them.
    private static let desktopTileAction = "AXRemoveDesktop"

    private static let missionControlPath = "/System/Applications/Mission Control.app"

    /// How long to wait for the Spaces bar to appear at all.
    private static let readinessTimeout: TimeInterval = 2.0
    private static let pollInterval: TimeInterval = 0.05

    /// Gap between a press and checking whether it took, which is also the re-press rate.
    private static let verifyDelay: TimeInterval = 0.2

    /// Overall budget for getting a switch to land.
    private static let switchTimeout: TimeInterval = 3.0

    /// How long to let an open request work before assuming it was lost — or that a
    /// swallowed press closed Mission Control again — and asking once more. Must exceed the
    /// ~450ms the Spaces bar takes to appear, or the request would be re-sent while
    /// Mission Control is still opening and toggle it straight back off.
    private static let reopenAfter: TimeInterval = 1.2

    /// Adding and removing are *not* idempotent, so they get one carefully-timed press
    /// instead of a loop: pressing twice would create or destroy two desktops. This delay
    /// is long enough that the first press is honoured in practice.
    private static let mutatingSettle: TimeInterval = 0.5
    private static let mutatingVerifyDelay: TimeInterval = 1.0

    /// True when the process may drive other applications through Accessibility.
    static var hasAccessibilityPermission: Bool {
        AXIsProcessTrusted()
    }

    /// Shows the system prompt that deep-links into Privacy & Security → Accessibility.
    static func requestAccessibilityPermission() {
        // Spelled literally: the SDK exports the key as a mutable global, which Swift 6
        // strict concurrency rejects.
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    // MARK: - Public actions

    /// Switches `display` to the desktop at `targetIndex` (0-based).
    @MainActor
    @discardableResult
    static func `switch`(to targetIndex: Int, on display: DisplaySpaces, screen: NSScreen?) -> Outcome {
        guard display.spaces.indices.contains(targetIndex) else { return .invalidTarget }
        guard targetIndex != display.currentIndex else { return .alreadyThere }
        guard hasAccessibilityPermission else { return .needsAccessibility }

        let spaceBefore = SkyLight.activeSpaceID()
        pressUntilSwitched(index: targetIndex,
                           spaceBefore: spaceBefore,
                           on: screen,
                           openedAt: nil,
                           deadline: Date().addingTimeInterval(switchTimeout))
        return .switching
    }

    /// Removes the desktop at `targetIndex`. Windows on it move to a neighbouring desktop;
    /// macOS itself does this without confirming, so neither does this.
    @MainActor
    @discardableResult
    static func removeDesktop(at targetIndex: Int, on display: DisplaySpaces, screen: NSScreen?) -> Outcome {
        // macOS keeps at least one desktop.
        guard display.spaces.count > 1 else { return .invalidTarget }
        guard display.spaces.indices.contains(targetIndex) else { return .invalidTarget }
        guard hasAccessibilityPermission else { return .needsAccessibility }

        performOnce(.remove, index: targetIndex, countBefore: display.spaces.count, on: screen)
        return .switching
    }

    /// Adds a desktop by pressing the Spaces bar's add button.
    @MainActor
    @discardableResult
    static func addDesktop(on display: DisplaySpaces, screen: NSScreen?) -> Outcome {
        guard hasAccessibilityPermission else { return .needsAccessibility }

        performOnce(.add, index: 0, countBefore: display.spaces.count, on: screen)
        return .switching
    }

    // MARK: - Mission Control

    /// Toggles Mission Control. It is an ordinary app bundle, so `open` suffices and no
    /// synthetic keystroke is involved.
    ///
    /// Deliberately without `-g`: opened in the background it can dismiss itself within
    /// ~300ms before any press lands, which was measured with several displays attached
    /// and left the widget flashing Mission Control without ever switching. Letting it
    /// activate normally keeps it up.
    private static func toggleMissionControl() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        task.arguments = ["-a", missionControlPath]
        try? task.run()
    }

    /// Closes Mission Control, but only if it is actually still up.
    @MainActor
    private static func dismissIfOpen(on screen: NSScreen?) {
        guard isMissionControlOpen(on: screen) else { return }
        toggleMissionControl()
    }

    /// The Spaces bar only exists while Mission Control is up, so its tiles are the tell.
    @MainActor
    private static func isMissionControlOpen(on screen: NSScreen?) -> Bool {
        guard let dock = dockElement() else { return false }
        return !desktopTiles(in: dock, on: screen).isEmpty
    }

    private static func dockElement() -> AXUIElement? {
        NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock")
            .first
            .map { AXUIElementCreateApplication($0.processIdentifier) }
    }

    // MARK: - Switching (idempotent, so it may retry freely)

    /// Presses the tile until `SLSGetActiveSpace` reports the move.
    ///
    /// `openedAt` carries when Mission Control was last asked to open. Requesting it on
    /// every poll would toggle it closed again a few tens of milliseconds later and it
    /// would never settle — that flapping is what made the first several switches after
    /// launch fail while later ones, with Mission Control already up, succeeded in ~300ms.
    @MainActor
    private static func pressUntilSwitched(index: Int, spaceBefore: UInt64?,
                                           on screen: NSScreen?, openedAt: Date?, deadline: Date) {
        if SkyLight.activeSpaceID() != spaceBefore {
            return                                  // landed; the press closed Mission Control
        }
        guard Date() < deadline else {
            dismissIfOpen(on: screen)
            return
        }

        guard let dock = dockElement() else { return }
        let tiles = desktopTiles(in: dock, on: screen)

        func again(_ openedAt: Date?, after delay: TimeInterval) {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                pressUntilSwitched(index: index, spaceBefore: spaceBefore,
                                   on: screen, openedAt: openedAt, deadline: deadline)
            }
        }

        guard tiles.indices.contains(index) else {
            // Not up yet, or a swallowed press closed it again. Ask at most once per
            // `reopenAfter` so the request has time to take effect.
            if openedAt == nil || Date().timeIntervalSince(openedAt!) > reopenAfter {
                toggleMissionControl()
                again(Date(), after: pollInterval)
            } else {
                again(openedAt, after: pollInterval)
            }
            return
        }

        AXUIElementPerformAction(tiles[index], kAXPressAction as CFString)
        again(openedAt, after: verifyDelay)
    }

    // MARK: - Adding and removing (not idempotent, so exactly one press)

    private enum MutatingAction {
        case remove
        case add
    }

    /// Waits for the Spaces bar, presses once, then reports by closing Mission Control.
    /// Deliberately never re-presses: a duplicate would add or delete a second desktop.
    @MainActor
    private static func performOnce(_ action: MutatingAction, index: Int, countBefore: Int,
                                    on screen: NSScreen?, openedAt: Date? = nil, deadline: Date? = nil) {
        let deadline = deadline ?? Date().addingTimeInterval(readinessTimeout)

        guard let dock = dockElement() else { return }
        let tiles = desktopTiles(in: dock, on: screen)

        guard tiles.count == countBefore, tiles.indices.contains(index) else {
            guard Date() < deadline else {
                dismissIfOpen(on: screen)
                return
            }
            // Ask to open at most once per `reopenAfter`; asking every poll would toggle
            // Mission Control back off before its Spaces bar ever appears.
            var openedAt = openedAt
            if openedAt == nil || Date().timeIntervalSince(openedAt!) > reopenAfter {
                toggleMissionControl()
                openedAt = Date()
            }
            let pending = openedAt
            DispatchQueue.main.asyncAfter(deadline: .now() + pollInterval) {
                performOnce(action, index: index, countBefore: countBefore,
                            on: screen, openedAt: pending, deadline: deadline)
            }
            return
        }

        // Give the Dock time to start honouring presses before the single attempt.
        DispatchQueue.main.asyncAfter(deadline: .now() + mutatingSettle) {
            guard let dock = dockElement() else { return }
            let tiles = desktopTiles(in: dock, on: screen)
            guard tiles.indices.contains(index) else {
                dismissIfOpen(on: screen)
                return
            }

            let target: AXUIElement?
            switch action {
            case .remove: target = tiles[index]
            // No add button means the desktop limit is reached and the Dock hides it.
            case .add: target = addButton(near: tiles[0])
            }
            guard let target else {
                dismissIfOpen(on: screen)
                return
            }

            let axAction = action == .remove ? desktopTileAction : kAXPressAction as String
            AXUIElementPerformAction(target, axAction as CFString)

            // Neither action closes Mission Control, so tidy up either way.
            DispatchQueue.main.asyncAfter(deadline: .now() + mutatingVerifyDelay) {
                dismissIfOpen(on: screen)
            }
        }
    }

    // MARK: - AX traversal

    /// The desktop tiles belonging to `screen`, left to right.
    ///
    /// Each display gets its own Spaces bar, so the tiles are grouped by the bar that owns
    /// them and the bar is matched to a display by *its* position. The tiles' own
    /// coordinates are useless for this — a collapsed bar reports them above the top of the
    /// screen (y = -32) — but the bar itself sits squarely on its display.
    private static func desktopTiles(in root: AXUIElement, on screen: NSScreen?) -> [AXUIElement] {
        var bars: [(bar: AXUIElement, tiles: [AXUIElement])] = []
        collectBars(root, depth: 0, into: &bars)

        guard let first = bars.first else { return [] }
        guard bars.count > 1, let screen else { return first.tiles }

        return bars.first { belongs($0.bar, to: screen) }?.tiles ?? first.tiles
    }

    /// Finds each Spaces bar: the element whose direct children are the desktop tiles.
    private static func collectBars(_ element: AXUIElement, depth: Int,
                                    into bars: inout [(bar: AXUIElement, tiles: [AXUIElement])]) {
        guard depth < 9 else { return }

        let kids = children(of: element)
        let tiles = kids.filter { child in
            var actions: CFArray?
            AXUIElementCopyActionNames(child, &actions)
            return ((actions as? [String]) ?? []).contains(desktopTileAction)
        }
        if !tiles.isEmpty {
            bars.append((element, tiles))
            return
        }
        for child in kids {
            collectBars(child, depth: depth + 1, into: &bars)
        }
    }

    /// AX reports positions with a top-left origin anchored on the primary display.
    private static func belongs(_ bar: AXUIElement, to screen: NSScreen) -> Bool {
        guard let origin = rawPosition(of: bar),
              let primary = NSScreen.screens.first(where: { $0.frame.origin == .zero })
        else { return false }

        let frame = screen.frame
        let topLeft = CGRect(x: frame.minX,
                             y: primary.frame.height - frame.maxY,
                             width: frame.width,
                             height: frame.height)
        return topLeft.contains(origin)
    }

    /// The add button sits beside the list that holds the tiles, not beside the tiles
    /// themselves, so reach it by walking up two levels from any tile.
    private static func addButton(near tile: AXUIElement) -> AXUIElement? {
        guard let list = parent(of: tile), let bar = parent(of: list) else { return nil }

        for child in children(of: bar) {
            var actions: CFArray?
            AXUIElementCopyActionNames(child, &actions)
            let names = (actions as? [String]) ?? []
            var role: CFTypeRef?
            AXUIElementCopyAttributeValue(child, kAXRoleAttribute as CFString, &role)
            if (role as? String) == kAXButtonRole as String,
               names.contains(kAXPressAction as String),
               !names.contains(desktopTileAction) {
                return child
            }
        }
        return nil
    }

    private static func children(of element: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success
        else { return [] }
        return (value as? [AXUIElement]) ?? []
    }

    private static func parent(of element: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXParentAttribute as CFString, &value) == .success,
              let raw = value, CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
        return (raw as! AXUIElement)
    }

    /// An element's position exactly as AX reports it: top-left origin, primary display.
    private static func rawPosition(of element: AXUIElement) -> CGPoint? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &value) == .success,
              let raw = value, CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }

        var point = CGPoint.zero
        guard AXValueGetValue(raw as! AXValue, .cgPoint, &point) else { return nil }
        return point
    }
}
