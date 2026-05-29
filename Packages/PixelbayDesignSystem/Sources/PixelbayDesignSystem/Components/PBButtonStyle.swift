import SwiftUI

// Shared button styles. `PB` prefix avoids collisions with SwiftUI's own
// `ButtonStyle` conformances. Usage: `.buttonStyle(.pbPrimary)` etc.
//
//   .pbPrimary      — accent-filled CTA (one per surface)
//   .pbSecondary    — elevated-surface, subtle border
//   .pbGhost        — text-only, hover-tinted
//   .pbDestructive  — danger-filled
//   .pbCompact      — small icon/transport button on elevated surface

public struct PBButtonStyle: ButtonStyle {
    public enum Kind {
        case primary, secondary, ghost, destructive, compact
    }

    let kind: Kind
    @Environment(\.isEnabled) private var isEnabled

    public init(_ kind: Kind) { self.kind = kind }

    public func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed
        return configuration.label
            .font(font)
            .foregroundStyle(foreground)
            .padding(.horizontal, hPadding)
            .padding(.vertical, vPadding)
            .frame(minHeight: minHeight)
            .background(background(pressed: pressed))
            .overlay(border)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous))
            .opacity(isEnabled ? (pressed ? 0.85 : 1) : 0.45)
            .contentShape(Rectangle())
            .animation(.easeOut(duration: 0.12), value: pressed)
    }

    private var font: Font {
        kind == .compact ? Theme.Font.caption : Theme.Font.bodyEmphasized
    }

    private var minHeight: CGFloat {
        switch kind {
        case .compact: return 24
        case .primary: return 36
        default: return 30
        }
    }

    private var hPadding: CGFloat {
        switch kind {
        case .compact: return Theme.Spacing.sm
        case .primary: return Theme.Spacing.xl
        default: return Theme.Spacing.lg
        }
    }

    private var vPadding: CGFloat { kind == .compact ? Theme.Spacing.xs : Theme.Spacing.sm }

    private var foreground: Color {
        switch kind {
        case .primary, .destructive: return Theme.Color.textPrimary
        case .secondary, .compact: return Theme.Color.textPrimary
        case .ghost: return Theme.Color.textSecondary
        }
    }

    private func background(pressed: Bool) -> Color {
        switch kind {
        case .primary:
            return Theme.Color.accent
        case .destructive:
            return Theme.Color.danger
        case .secondary, .compact:
            return Theme.Color.bgElevated
        case .ghost:
            return pressed ? Theme.Color.bgElevated : Color.clear
        }
    }

    @ViewBuilder
    private var border: some View {
        switch kind {
        case .secondary, .compact:
            RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous)
                .strokeBorder(Theme.Color.borderSubtle, lineWidth: Theme.Stroke.regular)
        default:
            EmptyView()
        }
    }
}

extension ButtonStyle where Self == PBButtonStyle {
    public static var pbPrimary: PBButtonStyle { PBButtonStyle(.primary) }
    public static var pbSecondary: PBButtonStyle { PBButtonStyle(.secondary) }
    public static var pbGhost: PBButtonStyle { PBButtonStyle(.ghost) }
    public static var pbDestructive: PBButtonStyle { PBButtonStyle(.destructive) }
    public static var pbCompact: PBButtonStyle { PBButtonStyle(.compact) }
}
