import SwiftUI

// House-style slider — a custom replacement for SwiftUI's native `Slider`,
// which can't be deeply restyled on macOS and reads as generic/OS-default.
//
// CONTRACT (load-bearing): this is a drop-in for `Slider(value:in:onEditingChanged:)`.
// Several call sites (clip volume/speed, cursor size, zoom factor) rely on the
// EXACT `onEditingChanged` semantics to record ONE undo command per drag
// instead of flooding the stack with per-tick edits:
//   • `onEditingChanged(true)` fires once at the start of a drag/tap,
//   • `value` is written continuously during the drag,
//   • the FINAL `value` is written BEFORE `onEditingChanged(false)` fires,
//     so the call site's drag-end handler sees the committed value.
// `DragGesture(minimumDistance: 0)` also gives click-to-position for free: a
// bare click fires one onChanged (→ true + write) then onEnded (→ write + false),
// i.e. exactly one true→write→false cycle = one committed edit.
//
// Tradeoff: a hand-rolled slider loses native VoiceOver slider role + hardware
// arrow-key increment. VoiceOver is restored via `.accessibilityAdjustableAction`
// below; hardware arrow-key focus (non-VO) is an accepted minor regression —
// none of these sliders are primary keyboard targets.

public struct PBSlider: View {
    public enum Size { case regular, mini }

    private let valueBinding: Binding<Double>
    private let bounds: ClosedRange<Double>
    private let size: Size
    private let onEditingChanged: (Bool) -> Void

    @State private var isEditing = false

    public init(
        value: Binding<Double>,
        in bounds: ClosedRange<Double>,
        size: Size = .regular,
        onEditingChanged: @escaping (Bool) -> Void = { _ in }
    ) {
        self.valueBinding = value
        self.bounds = bounds
        self.size = size
        self.onEditingChanged = onEditingChanged
    }

    private var thumbDiameter: CGFloat { size == .regular ? 14 : 11 }
    private var trackThickness: CGFloat { size == .regular ? 4 : 3 }
    private var controlHeight: CGFloat { size == .regular ? 20 : 16 }

    public var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let travel = max(1, w - thumbDiameter)
            let fraction = currentFraction()
            let fillWidth = CGFloat(fraction) * travel
            let thumbX = thumbDiameter / 2 + fillWidth

            ZStack(alignment: .topLeading) {
                // Unfilled track groove.
                Capsule()
                    .fill(Theme.Color.borderStrong)
                    .frame(width: travel, height: trackThickness)
                    .offset(x: thumbDiameter / 2, y: (h - trackThickness) / 2)

                // Accent fill from the track start to the thumb centre.
                Capsule()
                    .fill(Theme.Color.accent)
                    .frame(width: fillWidth, height: trackThickness)
                    .offset(x: thumbDiameter / 2, y: (h - trackThickness) / 2)

                // Thumb — white disc with a hairline rim + a tiny seating
                // shadow (depth, not glow).
                Circle()
                    .fill(.white)
                    .overlay(
                        Circle().strokeBorder(Theme.Color.borderSubtle, lineWidth: Theme.Stroke.hairline)
                    )
                    .frame(width: thumbDiameter, height: thumbDiameter)
                    .shadow(color: .black.opacity(0.25), radius: 1, y: 0.5)
                    .offset(x: thumbX - thumbDiameter / 2, y: (h - thumbDiameter) / 2)
            }
            .frame(width: w, height: h, alignment: .topLeading)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        if !isEditing {
                            isEditing = true
                            onEditingChanged(true)
                        }
                        write(atX: g.location.x, width: w)
                    }
                    .onEnded { g in
                        // Write the final value FIRST so the call site's
                        // drag-end handler reads the committed value, THEN
                        // signal end-of-edit.
                        write(atX: g.location.x, width: w)
                        isEditing = false
                        onEditingChanged(false)
                    }
            )
        }
        .frame(height: controlHeight)
        .accessibilityElement()
        .accessibilityValue(Text(accessibilityValueString))
        .accessibilityAdjustableAction { direction in
            let step = (bounds.upperBound - bounds.lowerBound) / 100
            switch direction {
            case .increment:
                valueBinding.wrappedValue = min(bounds.upperBound, valueBinding.wrappedValue + step)
            case .decrement:
                valueBinding.wrappedValue = max(bounds.lowerBound, valueBinding.wrappedValue - step)
            @unknown default:
                break
            }
        }
    }

    private func currentFraction() -> Double {
        Self.fraction(forValue: valueBinding.wrappedValue, in: bounds)
    }

    private func write(atX x: CGFloat, width w: CGFloat) {
        valueBinding.wrappedValue = Self.value(
            atX: x, width: w, thumbDiameter: thumbDiameter, in: bounds
        )
    }

    private var accessibilityValueString: String {
        "\(Int((currentFraction() * 100).rounded()))%"
    }

    // MARK: - Pure mapping (unit-tested)

    /// Normalised [0,1] position of `value` within `bounds` (clamped).
    static func fraction(forValue value: Double, in bounds: ClosedRange<Double>) -> Double {
        let span = bounds.upperBound - bounds.lowerBound
        guard span > 0 else { return 0 }
        return min(max((value - bounds.lowerBound) / span, 0), 1)
    }

    /// The value a pointer at `x` (in control-width `w`) maps to, accounting
    /// for the thumb radius inset at each end. Inverse of the thumb-position
    /// math used to render. Clamped to `bounds`.
    static func value(
        atX x: CGFloat, width w: CGFloat, thumbDiameter: CGFloat, in bounds: ClosedRange<Double>
    ) -> Double {
        let travel = max(1, w - thumbDiameter)
        let rawFraction = (x - thumbDiameter / 2) / travel
        let clamped = min(max(Double(rawFraction), 0), 1)
        let span = bounds.upperBound - bounds.lowerBound
        return bounds.lowerBound + clamped * span
    }
}

#if DEBUG
#Preview {
    struct Harness: View {
        @State private var volume = 0.8
        @State private var zoom = 0.4
        @State private var committed = "—"
        var body: some View {
            VStack(alignment: .leading, spacing: 24) {
                Text("regular").foregroundStyle(Theme.Color.textSecondary)
                PBSlider(value: $volume, in: 0...2, onEditingChanged: { editing in
                    if !editing { committed = String(format: "%.2f", volume) }
                })
                Text("mini").foregroundStyle(Theme.Color.textSecondary)
                PBSlider(value: $zoom, in: 0...1, size: .mini)
                Text("last committed: \(committed)").foregroundStyle(Theme.Color.textTertiary)
            }
            .padding(32)
            .frame(width: 320)
            .background(Theme.Color.bgBase)
        }
    }
    return Harness()
}
#endif
