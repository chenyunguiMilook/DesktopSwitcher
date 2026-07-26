import AppKit
import SwiftUI

/// Hosting view tuned for a panel that never becomes key.
///
/// Without `acceptsFirstMouse` a click on an inactive window is swallowed to activate it,
/// so the first click on a desktop pill would do nothing. Right-click is handled here in
/// AppKit rather than with SwiftUI's `.contextMenu` so that one code path decides the menu,
/// including whether the click landed on a specific pill.
final class SwitcherHostingView<Content: View>: NSHostingView<Content> {

    /// Builds the menu for a right-click. The argument is the pill that was hit, or nil
    /// when the click landed on the capsule background.
    var menuProvider: ((Int?) -> NSMenu)?

    /// How many pills are currently laid out, needed to hit-test them.
    var pillCount = 0


    /// Called for clicks and context menus — unambiguous intent, as opposed to hovering.
    var onInteraction: (() -> Void)?


    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func rightMouseDown(with event: NSEvent) {
        onInteraction?()
        guard let menu = menuProvider?(pillIndex(for: event)) else {
            super.rightMouseDown(with: event)
            return
        }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    /// Ctrl-click is the other conventional way to reach a context menu.
    override func mouseDown(with event: NSEvent) {
        onInteraction?()
        if event.modifierFlags.contains(.control), let menu = menuProvider?(pillIndex(for: event)) {
            NSMenu.popUpContextMenu(menu, with: event, for: self)
            return
        }
        super.mouseDown(with: event)
    }

    private func pillIndex(for event: NSEvent) -> Int? {
        let inView = convert(event.locationInWindow, from: nil)
        // AppKit's origin is bottom-left; the metrics describe a top-left layout.
        let flipped = CGPoint(x: inView.x, y: bounds.height - inView.y)
        return SwitcherMetrics.pillIndex(at: flipped, count: pillCount, viewHeight: bounds.height)
    }
}
