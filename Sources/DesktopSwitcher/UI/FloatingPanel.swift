import AppKit
import SwiftUI

/// Borderless always-on-top panel that hosts the switcher.
///
/// `.nonactivatingPanel` is the important bit: clicking a desktop must not pull focus
/// away from whatever the user was working in, otherwise the switcher would change the
/// front app as a side effect of changing desktop.
final class FloatingPanel: NSPanel {

    /// Set while the position is locked, which disables background dragging.
    var isPositionLocked = false {
        didSet { isMovableByWindowBackground = !isPositionLocked }
    }

    init(contentView: NSView) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 44),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        self.contentView = contentView

        isFloatingPanel = true
        level = .floating
        // .canJoinAllSpaces puts it on every desktop; .stationary stops it sliding with
        // the switch animation; .fullScreenAuxiliary lets it survive over full-screen apps.
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]

        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        isMovableByWindowBackground = true
        isReleasedWhenClosed = false
        animationBehavior = .none

        // Keep it out of screenshots of "all windows" and out of Mission Control.
        isExcludedFromWindowsMenu = true
    }

    /// Never becomes key, so typing focus stays with the user's real work.
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
