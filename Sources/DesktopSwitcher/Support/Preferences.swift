import AppKit
import ServiceManagement

/// Small persisted settings. Everything lives in `UserDefaults`; there is no settings
/// window, only the right-click menu.
@MainActor
enum Preferences {

    private enum Key {
        static let originX = "panel.origin.x"
        static let originY = "panel.origin.y"
        static let hasOrigin = "panel.origin.saved"
        static let locked = "panel.locked"
    }

    private static var defaults: UserDefaults { .standard }

    // MARK: - Panel position

    static var savedOrigin: NSPoint? {
        get {
            guard defaults.bool(forKey: Key.hasOrigin) else { return nil }
            return NSPoint(x: defaults.double(forKey: Key.originX),
                           y: defaults.double(forKey: Key.originY))
        }
        set {
            guard let newValue else {
                defaults.set(false, forKey: Key.hasOrigin)
                return
            }
            defaults.set(newValue.x, forKey: Key.originX)
            defaults.set(newValue.y, forKey: Key.originY)
            defaults.set(true, forKey: Key.hasOrigin)
        }
    }

    static var isPositionLocked: Bool {
        get { defaults.bool(forKey: Key.locked) }
        set { defaults.set(newValue, forKey: Key.locked) }
    }

    // MARK: - Launch at login

    static var launchesAtLogin: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Returns the error when the registration could not be changed, so the caller can
    /// surface it instead of silently doing nothing.
    static func setLaunchesAtLogin(_ enabled: Bool) -> Error? {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            return nil
        } catch {
            return error
        }
    }

    // MARK: - Placement

    /// A sensible first-run spot: bottom-centre of the main screen, above the Dock.
    static func defaultOrigin(for size: NSSize) -> NSPoint {
        guard let screen = NSScreen.main else { return NSPoint(x: 100, y: 100) }
        let frame = screen.visibleFrame
        return NSPoint(
            x: frame.midX - size.width / 2,
            y: frame.minY + 24
        )
    }

    /// Pulls a frame back onto a screen, for when a display was unplugged.
    static func clamped(_ frame: NSRect) -> NSRect {
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return frame }
        if screens.contains(where: { $0.frame.intersects(frame) }) { return frame }

        let visible = (NSScreen.main ?? screens[0]).visibleFrame
        var corrected = frame
        corrected.origin.x = min(max(frame.origin.x, visible.minX), visible.maxX - frame.width)
        corrected.origin.y = min(max(frame.origin.y, visible.minY), visible.maxY - frame.height)
        return corrected
    }
}
