import AppKit
import SwiftUI

/// Owns mouse interaction for a panel that never becomes key.
///
/// `NSHostingView` swallows mouse-down, so `isMovableByWindowBackground` never saw an
/// unhandled event and the widget could not be dragged at all. Rather than carve a drag
/// handle out of an already-tiny capsule, AppKit takes the whole gesture: a press that
/// moves becomes a window drag, a press that does not becomes a click on whatever is under
/// the pointer. Dragging therefore works from anywhere, including from the buttons.
///
/// The consequence is that SwiftUI never sees the press, so the pill views are plain
/// visuals and this class dispatches their actions. Hover still comes from SwiftUI, which
/// only needs mouse-moved events.
final class SwitcherHostingView<Content: View>: NSHostingView<Content> {

    /// Builds the menu for a right-click, given the pill that was hit or nil for the
    /// capsule background.
    var menuProvider: ((Int?) -> NSMenu)?

    /// Invoked when a press ends without turning into a drag.
    var onActivate: ((SwitcherMetrics.Element) -> Void)?

    /// Any press, drag or menu — used to wake the widget from its idle fade.
    var onInteraction: (() -> Void)?

    var desktopCount = 0
    var showsInputToggle = false

    /// Far enough that a click with a shaky hand — or over a laggy remote session — is
    /// still a click, short enough that a deliberate drag starts immediately.
    private let dragThreshold: CGFloat = 4

    private var pressedElement: SwitcherMetrics.Element?
    private var pressOrigin: NSPoint = .zero
    private var windowOriginAtPress: NSPoint = .zero
    private var isPressed = false
    private var isDragging = false

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: - Press, drag, click

    override func mouseDown(with event: NSEvent) {
        onInteraction?()

        if event.modifierFlags.contains(.control) {
            showMenu(for: event)
            return
        }

        pressedElement = element(for: event)
        // Screen space on both counts, since the window itself is about to move.
        pressOrigin = NSEvent.mouseLocation
        windowOriginAtPress = window?.frame.origin ?? .zero
        isPressed = true
        isDragging = false
        // Deliberately not forwarding to super: this class decides drag vs click.
    }

    /// Moves the window by hand rather than calling `performDrag(with:)`, which did nothing
    /// for this borderless, non-activating panel. Tracking the offset ourselves also keeps
    /// the press-versus-drag decision in one place.
    override func mouseDragged(with event: NSEvent) {
        guard isPressed, let panel = window as? FloatingPanel, !panel.isPositionLocked else { return }

        let current = NSEvent.mouseLocation
        let offset = CGPoint(x: current.x - pressOrigin.x, y: current.y - pressOrigin.y)

        if !isDragging {
            guard hypot(offset.x, offset.y) > dragThreshold else { return }
            isDragging = true
            pressedElement = nil          // a drag must not also count as a click
        }

        panel.setFrameOrigin(NSPoint(x: windowOriginAtPress.x + offset.x,
                                     y: windowOriginAtPress.y + offset.y))
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            isPressed = false
            pressedElement = nil
            isDragging = false
        }
        guard !isDragging, let pressed = pressedElement else { return }
        // Require the release to land on whatever was pressed, the way a button behaves.
        guard element(for: event) == pressed, pressed != .background else { return }
        onActivate?(pressed)
    }

    // MARK: - Context menu

    override func rightMouseDown(with event: NSEvent) {
        onInteraction?()
        showMenu(for: event)
    }

    private func showMenu(for event: NSEvent) {
        guard let menu = menuProvider?(pillIndex(for: event)) else { return }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    // MARK: - Hit testing

    private func flippedPoint(for event: NSEvent) -> CGPoint {
        let inView = convert(event.locationInWindow, from: nil)
        // AppKit's origin is bottom-left; the metrics describe a top-left layout.
        return CGPoint(x: inView.x, y: bounds.height - inView.y)
    }

    private func element(for event: NSEvent) -> SwitcherMetrics.Element {
        SwitcherMetrics.element(at: flippedPoint(for: event),
                                desktopCount: desktopCount,
                                showsInputToggle: showsInputToggle,
                                viewHeight: bounds.height)
    }

    private func pillIndex(for event: NSEvent) -> Int? {
        SwitcherMetrics.pillIndex(at: flippedPoint(for: event),
                                  count: desktopCount,
                                  showsInputToggle: showsInputToggle,
                                  viewHeight: bounds.height)
    }
}
