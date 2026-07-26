import CoreGraphics

/// Layout constants for the pill row, shared by the SwiftUI view and by the AppKit
/// right-click hit test so the two cannot drift apart.
enum SwitcherMetrics {

    static let pillSize: CGFloat = 26
    static let pillRadius: CGFloat = 7
    static let spacing: CGFloat = 5
    static let padding: CGFloat = 6

    static var capsuleRadius: CGFloat { pillRadius + padding }

    /// Which pill contains `point`, in the hosting view's coordinate space.
    ///
    /// Only the horizontal position selects a pill; vertically it is enough to be inside
    /// the padded band, since the pills fill it. Returns nil for the padding, for the
    /// permission dot, and for any gap between pills.
    static func pillIndex(at point: CGPoint, count: Int, viewHeight: CGFloat) -> Int? {
        guard count > 0 else { return nil }
        guard point.y >= padding, point.y <= viewHeight - padding else { return nil }

        let offset = point.x - padding
        guard offset >= 0 else { return nil }

        let stride = pillSize + spacing
        let index = Int(offset / stride)
        guard index < count else { return nil }

        // Reject the gap that follows each pill.
        let withinPill = offset - CGFloat(index) * stride
        guard withinPill <= pillSize else { return nil }

        return index
    }
}
