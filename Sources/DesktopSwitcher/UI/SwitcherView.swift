import SwiftUI

/// The row of desktop pills. Deliberately plain: a material capsule, one small
/// rounded square per desktop, the active one filled.
struct SwitcherView: View {

    @Bindable var model: SwitcherModel

    private let pillSize = SwitcherMetrics.pillSize
    private let pillRadius = SwitcherMetrics.pillRadius
    private let spacing = SwitcherMetrics.spacing
    private let padding = SwitcherMetrics.padding

    var body: some View {
        HStack(spacing: spacing) {
            content
        }
        .padding(padding)
        .background {
            RoundedRectangle(cornerRadius: SwitcherMetrics.capsuleRadius, style: .continuous)
                .fill(.regularMaterial)
                .overlay {
                    RoundedRectangle(cornerRadius: SwitcherMetrics.capsuleRadius, style: .continuous)
                        .strokeBorder(.primary.opacity(0.08), lineWidth: 1)
                }
        }
        .fixedSize()
    }

    @ViewBuilder
    private var content: some View {
        if !model.isSupported {
            message("不可用")
        } else if let display = model.display, !display.spaces.isEmpty {
            ForEach(Array(display.spaces.enumerated()), id: \.element.id) { index, space in
                DesktopPill(
                    number: index + 1,
                    isCurrent: index == display.currentIndex,
                    size: pillSize,
                    radius: pillRadius
                ) {
                    model.select(index)
                }
            }
            AddDesktopPill(size: pillSize, radius: pillRadius) {
                model.addDesktop()
            }
            if model.needsAccessibility {
                // One small dot rather than an outline on every pill: the row stays calm
                // and the hint disappears for good once permission is granted.
                Circle()
                    .fill(.orange)
                    .frame(width: 5, height: 5)
                    .help("需要辅助功能权限才能切换桌面，右键菜单可前往授权")
                    .transition(.opacity)
            }
        } else {
            message("…")
        }
    }

    private func message(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .medium, design: .rounded))
            .foregroundStyle(.secondary)
            .frame(height: pillSize)
            .padding(.horizontal, 6)
    }
}

/// Trailing "+" that creates a desktop. Styled a notch quieter than the numbers so the
/// row still reads as a list of desktops first.
private struct AddDesktopPill: View {

    let size: CGFloat
    let radius: CGFloat
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            ZStack {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(Color.primary.opacity(isHovering ? 0.22 : 0.04))
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(.primary.opacity(isHovering ? 0.45 : 0), lineWidth: 1.5)
                Image(systemName: "plus")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(isHovering ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
            }
            .frame(width: size, height: size)
            .scaleEffect(isHovering ? 1.08 : 1)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help("添加桌面")
        .animation(.easeOut(duration: 0.12), value: isHovering)
    }
}

/// A single desktop button.
private struct DesktopPill: View {

    let number: Int
    let isCurrent: Bool
    let size: CGFloat
    let radius: CGFloat
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            ZStack {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(fill)
                // A stroke plus a slight bump survive the idle fade, where a subtle fill
                // alone gets multiplied down to nothing by the window's alpha.
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(.primary.opacity(isHovering && !isCurrent ? 0.45 : 0), lineWidth: 1.5)
                Text("\(number)")
                    .font(.system(size: 12, weight: isCurrent ? .semibold : .medium, design: .rounded))
                    .foregroundStyle(isCurrent ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
            }
            .frame(width: size, height: size)
            .scaleEffect(isHovering ? 1.08 : 1)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help("桌面 \(number)")
        .animation(.easeOut(duration: 0.12), value: isCurrent)
        .animation(.easeOut(duration: 0.12), value: isHovering)
    }

    private var fill: AnyShapeStyle {
        if isCurrent { return AnyShapeStyle(Color.accentColor) }
        if isHovering { return AnyShapeStyle(Color.primary.opacity(0.22)) }
        return AnyShapeStyle(Color.primary.opacity(0.06))
    }

}
