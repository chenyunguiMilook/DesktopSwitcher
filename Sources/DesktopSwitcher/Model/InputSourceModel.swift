import AppKit
import Observation

/// Tracks the keyboard input source and flips between Chinese and Latin.
///
/// It remembers the last source used on each side rather than picking the first match,
/// which matters as soon as more than one Chinese IME is installed: someone typing Wubi
/// should get Wubi back, not whichever Pinyin entry happens to come first in the list.
@Observable
@MainActor
final class InputSourceModel {

    /// "中" or "A" — what is active now, matching how the menu bar reads.
    private(set) var label = "A"
    private(set) var isChinese = false
    private(set) var currentName = ""

    /// False when the machine has nothing to toggle between, in which case the button is
    /// pointless and stays hidden even if the user turned it on.
    private(set) var canToggle = false

    // Internal bookkeeping, not view state, so keep it out of observation tracking.
    @ObservationIgnored private var lastChineseID: String?
    @ObservationIgnored private var lastLatinID: String?

    // Touched from `deinit`, which is nonisolated; only written during init.
    @ObservationIgnored private nonisolated(unsafe) var observer: NSObjectProtocol?

    init() {
        refresh()
        observer = DistributedNotificationCenter.default().addObserver(
            forName: InputSourceSwitcher.changeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    deinit {
        if let observer {
            DistributedNotificationCenter.default().removeObserver(observer)
        }
    }

    /// Re-reads the active source and records it as the preferred one for its side.
    func refresh() {
        let sources = InputSourceSwitcher.available()
        canToggle = sources.contains(where: \.isChinese) && sources.contains(where: { !$0.isChinese })

        guard let current = InputSourceSwitcher.current() else { return }

        if current.isChinese {
            lastChineseID = current.id
        } else {
            lastLatinID = current.id
        }

        isChinese = current.isChinese
        label = current.isChinese ? "中" : "A"
        currentName = current.name
    }

    /// Switches to the other side, preferring whichever source was last used there.
    func toggle() {
        let sources = InputSourceSwitcher.available()
        let wantChinese = !isChinese
        let remembered = wantChinese ? lastChineseID : lastLatinID

        let target = sources.first { $0.id == remembered && $0.isChinese == wantChinese }
            ?? sources.first { $0.isChinese == wantChinese }
        guard let target else { return }

        InputSourceSwitcher.select(target)
        // The notification is the authoritative update, but reflecting it right away keeps
        // the button from lagging behind the click.
        refresh()
    }
}
