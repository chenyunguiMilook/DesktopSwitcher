import CoreGraphics

/// The capsule's layout, in one place.
///
/// SwiftUI lays the row out from these constants and AppKit hit-tests against them, so the
/// two cannot drift apart. AppKit owns the clicking: `NSHostingView` swallows mouse-down,
/// which both broke window dragging and made SwiftUI `Button`s the only way to act on a
/// click. Driving both from this model instead means a press can turn into a drag or a
/// click depending on whether the pointer moved.
enum SwitcherMetrics {

    static let pillSize: CGFloat = 26
    static let pillRadius: CGFloat = 7
    static let spacing: CGFloat = 5
    static let padding: CGFloat = 6

    /// The hairline between the desktop controls and the input toggle: 1pt rule with 1pt
    /// of breathing room on each side.
    static let dividerWidth: CGFloat = 3

    static var capsuleRadius: CGFloat { pillRadius + padding }

    /// What sits under a point.
    enum Element: Equatable {
        case desktop(Int)
        case addDesktop
        case inputToggle
        /// Padding, gaps, the divider, the permission dot — anything not actionable.
        case background
    }

    /// Resolves a point in the hosting view's flipped (top-left origin) space.
    static func element(at point: CGPoint,
                        desktopCount: Int,
                        showsInputToggle: Bool,
                        viewHeight: CGFloat) -> Element {
        guard point.y >= padding, point.y <= viewHeight - padding else { return .background }

        var x = padding

        for index in 0..<max(desktopCount, 0) {
            if point.x >= x, point.x <= x + pillSize { return .desktop(index) }
            x += pillSize + spacing
        }

        if point.x >= x, point.x <= x + pillSize { return .addDesktop }
        x += pillSize + spacing

        if showsInputToggle {
            x += dividerWidth + spacing
            if point.x >= x, point.x <= x + pillSize { return .inputToggle }
        }

        return .background
    }

    /// Convenience for the right-click menu, which only cares about desktop pills.
    static func pillIndex(at point: CGPoint,
                          count: Int,
                          showsInputToggle: Bool = false,
                          viewHeight: CGFloat) -> Int? {
        if case .desktop(let index) = element(at: point,
                                              desktopCount: count,
                                              showsInputToggle: showsInputToggle,
                                              viewHeight: viewHeight) {
            return index
        }
        return nil
    }
}
