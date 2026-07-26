import AppKit

/// Watches for anything that can change the desktop list or the active desktop.
///
/// `activeSpaceDidChangeNotification` covers switching. Adding or removing a desktop in
/// Mission Control posts nothing, so a low-frequency poll backs it up. The poll is one
/// cheap IPC call plus a struct comparison, and `SwitcherModel.refresh()` drops it when
/// nothing changed.
@MainActor
final class SpaceMonitor {

    private static let pollInterval: TimeInterval = 1.5

    private let onChange: () -> Void

    // Touched from `deinit`, which is nonisolated. Both are only ever written during
    // `init` on the main actor, so unchecked access in `deinit` is safe.
    private nonisolated(unsafe) var timer: Timer?
    private nonisolated(unsafe) var observers: [NSObjectProtocol] = []

    init(onChange: @escaping () -> Void) {
        self.onChange = onChange

        let workspaceCenter = NSWorkspace.shared.notificationCenter
        observers.append(
            workspaceCenter.addObserver(
                forName: NSWorkspace.activeSpaceDidChangeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.onChange() }
            }
        )

        observers.append(
            NotificationCenter.default.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.onChange() }
            }
        )

        let timer = Timer(timeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.onChange() }
        }
        // .common keeps the poll alive while the user drags the panel around.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    deinit {
        timer?.invalidate()
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        for observer in observers {
            workspaceCenter.removeObserver(observer)
            NotificationCenter.default.removeObserver(observer)
        }
    }
}
