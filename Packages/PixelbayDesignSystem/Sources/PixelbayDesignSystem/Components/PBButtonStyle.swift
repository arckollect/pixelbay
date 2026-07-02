import SwiftUI

// Shared button styles. `PB` prefix avoids collisions with SwiftUI's own
// `ButtonStyle` conformances. Usage: `.buttonStyle(.pbPrimary)` etc.
//
//   .pbPrimary      — accent-filled CTA (one per surface)
//   .pbSecondary    — elevated-surface, subtle border
//   .pbGhost        — text-only, hover-tinted
//   .pbDestructive  — danger-filled
//   .pbCompact      — small icon/transport button on elevated surface
//
// Every kind reacts to hover as well as press — a static control on a
// pointer-driven platform reads as disabled. Hover lightens the surface
// (or, for filled kinds, washes it with white); press darkens/dims.

public struct PBButtonStyle: ButtonStyle {
    public enum Kind {
        case primary, secondary, ghost, destructive, compact
    }

    let kind: Kind

    public init(_ kind: Kind) { self.kind = kind }

    public func makeBody(configuration: Configuration) -> some View {
        StyledBody(kind: kind, configuration: configuration)
    }

    // Inner view so hover state can live in @State (ButtonStyle itself is
    // recreated per body pass and can't hold it). Named to avoid colliding
    // with ButtonStyle's `Body` associated type.
    private struct StyledBody: View {
        let kind: Kind
        let configuration: Configuration
        @Environment(\.isEnabled) private var isEnabled
        @State private var hovered = false

        var body: some View {
            let pressed = configuration.isPressed
            configuration.label
                .font(font)
                .foregroundStyle(foreground)
                .padding(.horizontal, hPadding)
                .padding(.vertical, vPadding)
                .frame(minHeight: minHeight)
                .background(background(pressed: pressed))
                .overlay(hoverWash(pressed: pressed))
                .overlay(border)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous))
                .opacity(isEnabled ? (pressed ? 0.85 : 1) : 0.45)
                .contentShape(Rectangle())
                .animation(.easeOut(duration: 0.12), value: pressed)
                .animation(.easeOut(duration: 0.12), value: hovered)
                .onHover { hovered = isEnabled && $0 }
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
            case .ghost: return hovered ? Theme.Color.textPrimary : Theme.Color.textSecondary
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
                return (pressed || hovered) ? Theme.Color.bgElevated : Color.clear
            }
        }

        // Filled kinds brighten on hover via a white wash (tinting the fill
        // itself would need per-kind "lighter" tokens); unfilled kinds handle
        // hover in `background` instead.
        @ViewBuilder
        private func hoverWash(pressed: Bool) -> some View {
            if hovered && !pressed {
                switch kind {
                case .primary, .destructive:
                    Color.white.opacity(0.10)
                case .secondary, .compact:
                    Color.white.opacity(0.05)
                case .ghost:
                    EmptyView()
                }
            }
        }

        @ViewBuilder
        private var border: some View {
            switch kind {
            case .secondary, .compact:
                RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous)
                    .strokeBorder(
                        hovered ? Theme.Color.borderStrong : Theme.Color.borderSubtle,
                        lineWidth: Theme.Stroke.regular
                    )
            default:
                EmptyView()
            }
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
