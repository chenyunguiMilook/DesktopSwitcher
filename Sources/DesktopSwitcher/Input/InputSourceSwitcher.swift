import Carbon
import Foundation

/// Thin wrapper over Text Input Services.
///
/// Unlike the Space machinery, this is all public API — `TISSelectInputSource` needs no
/// Accessibility grant and works directly.
enum InputSourceSwitcher {

    struct Source: Equatable {
        let id: String
        let name: String
        /// True when the source types Chinese, judged by its declared languages rather
        /// than by matching bundle identifiers, so third-party IMEs classify correctly.
        let isChinese: Bool

        fileprivate let ref: TISInputSource

        static func == (a: Source, b: Source) -> Bool { a.id == b.id }
    }

    /// Every enabled, selectable keyboard source, in the order the system reports them.
    static func available() -> [Source] {
        let list = TISCreateInputSourceList(nil, false)?.takeRetainedValue() as? [TISInputSource] ?? []
        return list.compactMap { source in
            guard string(source, kTISPropertyInputSourceCategory) == (kTISCategoryKeyboardInputSource as String),
                  flag(source, kTISPropertyInputSourceIsSelectCapable),
                  let id = string(source, kTISPropertyInputSourceID)
            else { return nil }

            return Source(id: id,
                          name: string(source, kTISPropertyLocalizedName) ?? id,
                          isChinese: languages(source).contains { $0.hasPrefix("zh") },
                          ref: source)
        }
    }

    static func current() -> Source? {
        guard let ref = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let id = string(ref, kTISPropertyInputSourceID) else { return nil }

        return Source(id: id,
                      name: string(ref, kTISPropertyLocalizedName) ?? id,
                      isChinese: languages(ref).contains { $0.hasPrefix("zh") },
                      ref: ref)
    }

    @discardableResult
    static func select(_ source: Source) -> Bool {
        TISSelectInputSource(source.ref) == noErr
    }

    /// Posted by the system whenever the selected keyboard source changes, including
    /// changes made from the menu bar or by a keyboard shortcut.
    static var changeNotification: Notification.Name {
        Notification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String)
    }

    // MARK: - Property helpers

    private static func string(_ source: TISInputSource, _ key: CFString) -> String? {
        guard let pointer = TISGetInputSourceProperty(source, key) else { return nil }
        return Unmanaged<CFString>.fromOpaque(pointer).takeUnretainedValue() as String
    }

    private static func flag(_ source: TISInputSource, _ key: CFString) -> Bool {
        guard let pointer = TISGetInputSourceProperty(source, key) else { return false }
        return CFBooleanGetValue(Unmanaged<CFBoolean>.fromOpaque(pointer).takeUnretainedValue())
    }

    private static func languages(_ source: TISInputSource) -> [String] {
        guard let pointer = TISGetInputSourceProperty(source, kTISPropertyInputSourceLanguages) else { return [] }
        return (Unmanaged<CFArray>.fromOpaque(pointer).takeUnretainedValue() as? [String]) ?? []
    }
}
