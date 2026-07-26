import AppKit
import ApplicationServices

/// One user desktop on a display.
struct Space: Identifiable, Equatable, Sendable {
    /// WindowServer's internal id. Not contiguous and not the number the user sees.
    let managedID: UInt64
    let uuid: String

    var id: UInt64 { managedID }
}

/// The desktops of a single display, in Mission Control's left-to-right order.
struct DisplaySpaces: Equatable, Sendable {
    let displayIdentifier: String
    let spaces: [Space]
    let currentSpaceID: UInt64?

    /// Position of the active desktop, which is also its user-visible number minus one.
    var currentIndex: Int? {
        guard let currentSpaceID else { return nil }
        return spaces.firstIndex { $0.managedID == currentSpaceID }
    }

    static let empty = DisplaySpaces(displayIdentifier: "", spaces: [], currentSpaceID: nil)
}

/// Turns SkyLight's raw topology dictionaries into `DisplaySpaces` values.
enum SpaceReader {

    /// Space `type` 0 is an ordinary desktop; 4 is a full-screen app and 2 a tiled pair.
    /// The widget only manages desktops, so everything else is filtered out.
    private static let desktopSpaceType = 0

    /// Reads every display's desktops.
    static func readAll() -> [DisplaySpaces] {
        SkyLight.managedDisplaySpaces().compactMap(parse)
    }

    /// Reads the desktops of the display that `screen` sits on.
    ///
    /// Falls back to the first display when the screen cannot be matched — a single
    /// display sometimes reports the identifier `"Main"` rather than a UUID.
    static func read(for screen: NSScreen?) -> DisplaySpaces? {
        let all = readAll()
        guard !all.isEmpty else { return nil }
        guard let screen, let uuid = displayIdentifier(for: screen) else { return all.first }
        return all.first { $0.displayIdentifier == uuid } ?? all.first
    }

    private static func parse(_ raw: [String: Any]) -> DisplaySpaces? {
        guard let identifier = raw["Display Identifier"] as? String else { return nil }

        let spaces = (raw["Spaces"] as? [[String: Any]] ?? []).compactMap { entry -> Space? in
            guard (entry["type"] as? Int) == desktopSpaceType,
                  let managedID = entry["ManagedSpaceID"] as? UInt64 else { return nil }
            return Space(managedID: managedID, uuid: entry["uuid"] as? String ?? "")
        }

        let current = (raw["Current Space"] as? [String: Any])?["ManagedSpaceID"] as? UInt64

        return DisplaySpaces(displayIdentifier: identifier, spaces: spaces, currentSpaceID: current)
    }

    /// The display UUID string SkyLight uses to key a display.
    static func displayIdentifier(for screen: NSScreen) -> String? {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        guard let number = screen.deviceDescription[key] as? NSNumber else { return nil }
        let displayID = CGDirectDisplayID(number.uint32Value)
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue() else { return nil }
        return CFUUIDCreateString(nil, uuid) as String
    }
}
