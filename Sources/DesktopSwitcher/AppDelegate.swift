import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var panel: FloatingPanel?
    private var model: SwitcherModel?
    private var hostingView: SwitcherHostingView<SwitcherView>?
    private var frameObserver: NSObjectProtocol?
    private var moveObserver: NSObjectProtocol?
    private var fader: IdleFader?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let model = SwitcherModel()
        self.model = model

        let hostingView = SwitcherHostingView(rootView: SwitcherView(model: model))
        hostingView.menuProvider = { [weak self] pill in self?.buildMenu(for: pill) ?? NSMenu() }
        hostingView.onInteraction = { [weak self] in self?.fader?.noteInteraction() }
        self.hostingView = hostingView

        let panel = FloatingPanel(contentView: hostingView)
        self.panel = panel

        // Registered before the first placement so even the default position is stored.
        // didMoveNotification is the reliable signal: background dragging, setFrame and
        // programmatic repositioning all post it, whereas overriding setFrameOrigin
        // misses the setFrame path.
        moveObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification,
            object: panel,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.panelDidMove() }
        }

        panel.isPositionLocked = Preferences.isPositionLocked
        // Force SwiftUI to lay out before measuring, otherwise the first `fittingSize`
        // is a partial one and the default centring lands off by half a pill.
        hostingView.layoutSubtreeIfNeeded()
        sizeToFit()
        placeInitially()
        panel.orderFrontRegardless()
        fader = IdleFader(panel: panel)

        model.screen = panel.screen

        // Content width changes whenever a desktop is added or removed.
        hostingView.postsFrameChangedNotifications = true
        frameObserver = NotificationCenter.default.addObserver(
            forName: NSView.frameDidChangeNotification,
            object: hostingView,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.sizeToFit() }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        for observer in [frameObserver, moveObserver].compactMap({ $0 }) {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: - Geometry

    /// Keeps the panel exactly as wide as its content, anchored at its top-left so it
    /// grows rightward rather than jumping when the desktop count changes.
    private func sizeToFit() {
        guard let panel, let hostingView else { return }
        let size = hostingView.fittingSize
        guard size.width > 0, size.height > 0 else { return }
        hostingView.pillCount = model?.display?.spaces.count ?? 0

        var frame = panel.frame
        let topLeft = NSPoint(x: frame.minX, y: frame.maxY)
        frame.size = size
        frame.origin = NSPoint(x: topLeft.x, y: topLeft.y - size.height)
        panel.setFrame(Preferences.clamped(frame), display: true)
    }

    private func placeInitially() {
        guard let panel else { return }
        let origin = Preferences.savedOrigin ?? Preferences.defaultOrigin(for: panel.frame.size)
        var frame = panel.frame
        frame.origin = origin
        panel.setFrame(Preferences.clamped(frame), display: true)
    }

    private func panelDidMove() {
        guard let panel else { return }
        Preferences.savedOrigin = panel.frame.origin
        // Dragging onto another display must swap which display's desktops are shown.
        model?.screen = panel.screen
    }

    // MARK: - Menu

    private func buildMenu(for pillIndex: Int?) -> NSMenu {
        let menu = NSMenu()

        // A right-click that landed on a pill gets that desktop's own actions first.
        if let pillIndex, let display = model?.display, display.spaces.indices.contains(pillIndex) {
            let switchItem = NSMenuItem(title: "切换到桌面 \(pillIndex + 1)",
                                        action: #selector(switchToTaggedDesktop(_:)), keyEquivalent: "")
            switchItem.target = self
            switchItem.tag = pillIndex
            switchItem.isEnabled = pillIndex != display.currentIndex
            menu.addItem(switchItem)

            let removeItem = NSMenuItem(title: "删除桌面 \(pillIndex + 1)",
                                        action: #selector(removeTaggedDesktop(_:)), keyEquivalent: "")
            removeItem.target = self
            removeItem.tag = pillIndex
            // macOS keeps at least one desktop.
            removeItem.isEnabled = display.spaces.count > 1
            menu.addItem(removeItem)

            menu.addItem(.separator())
        }

        let lock = NSMenuItem(title: "锁定位置", action: #selector(toggleLock), keyEquivalent: "")
        lock.target = self
        lock.state = Preferences.isPositionLocked ? .on : .off
        menu.addItem(lock)

        let login = NSMenuItem(title: "开机启动", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        login.target = self
        login.state = Preferences.launchesAtLogin ? .on : .off
        menu.addItem(login)

        menu.addItem(.separator())

        if model?.needsAccessibility == true || !SpaceSwitcher.hasAccessibilityPermission {
            let grant = NSMenuItem(title: "授予辅助功能权限…", action: #selector(openAccessibilitySettings), keyEquivalent: "")
            grant.target = self
            menu.addItem(grant)
        }

        let reset = NSMenuItem(title: "重置位置", action: #selector(resetPosition), keyEquivalent: "")
        reset.target = self
        menu.addItem(reset)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "退出", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        return menu
    }

    @objc private func switchToTaggedDesktop(_ sender: NSMenuItem) {
        model?.select(sender.tag)
    }

    @objc private func removeTaggedDesktop(_ sender: NSMenuItem) {
        model?.remove(sender.tag)
    }

    @objc private func toggleLock() {
        Preferences.isPositionLocked.toggle()
        panel?.isPositionLocked = Preferences.isPositionLocked
    }

    @objc private func toggleLaunchAtLogin() {
        let enable = !Preferences.launchesAtLogin
        if let error = Preferences.setLaunchesAtLogin(enable) {
            let alert = NSAlert(error: error)
            alert.messageText = "无法修改开机启动"
            alert.runModal()
        }
    }

    @objc private func openAccessibilitySettings() {
        SpaceSwitcher.requestAccessibilityPermission()
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func resetPosition() {
        guard let panel else { return }
        Preferences.savedOrigin = nil
        var frame = panel.frame
        frame.origin = Preferences.defaultOrigin(for: frame.size)
        panel.setFrame(frame, display: true)
        Preferences.savedOrigin = frame.origin
        model?.screen = panel.screen
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
