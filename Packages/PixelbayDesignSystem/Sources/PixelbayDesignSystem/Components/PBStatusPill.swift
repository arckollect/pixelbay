import SwiftUI

// Small status pill — "Recording" / "Ready" / "Idle" and friends. A coloured
// dot plus a label on a tinted capsule. The `.recording` style pulses its dot.

public struct PBStatusPill: View {
    public enum Style {
        case recording, ready, idle, warning, custom(Color)

        var color: Color {
            switch self {
            case .recording: return Theme.Color.recordingRed
            case .ready: return Theme.Color.success
            case .idle: return Theme.Color.textTertiary
            case .warning: return Theme.Color.warning
            case .custom(let c): return c
            }
        }

        var pulses: Bool {
            if case .recording = self { return true }
            return false
        }
    }

    let text: String
    let style: Style
    @State private var pulse = false

    public init(_ text: String, style: Style) {
        self.text = text
        self.style = style
    }

    public var body: some View {
        HStack(spacing: Theme.Spacing.xs) {
            Circle()
                .fill(style.color)
                .frame(width: 7, height: 7)
                .opacity(style.pulses ? (pulse ? 0.35 : 1) : 1)
                .animation(style.pulses ? .easeInOut(duration: 0.9).repeatForever(autoreverses: true) : .default, value: pulse)
            Text(text)
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.Color.textPrimary)
        }
        .padding(.horizontal, Theme.Spacing.sm)
        .padding(.vertical, Theme.Spacing.xs)
        .background(style.color.opacity(0.16))
        .clipShape(Capsule())
        .overlay(Capsule().strokeBorder(style.color.opacity(0.35), lineWidth: Theme.Stroke.hairline))
        .onAppear { if style.pulses { pulse = true } }
    }
}
