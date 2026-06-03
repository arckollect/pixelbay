import SwiftUI

// Gentle tonal-depth modifier: seats a control grouping in a subtle inset
// "well" so it reads as intentional rather than floating on a flat plane —
// without introducing hard panels. `bgInsetCard` (#1F1F1F) sits a touch above
// the inspector's `bgDeep`/`bgBase`, with a hairline border and a faint
// lit-from-above top highlight (depth, not glow). Apply to slider/segmented
// control groupings; use sparingly so the inspector stays airy.

public extension View {
    func pbInsetRow() -> some View {
        self
            .padding(.horizontal, Theme.Spacing.md)
            .padding(.vertical, Theme.Spacing.sm)
            .background(Theme.Color.bgInsetCard)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.medium))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.medium)
                    .strokeBorder(Theme.Color.borderSubtle, lineWidth: Theme.Stroke.hairline)
            )
            .overlay(alignment: .top) {
                // Faint top highlight — a thin lit edge that catches the light.
                RoundedRectangle(cornerRadius: Theme.Radius.medium)
                    .fill(Color.white.opacity(0.05))
                    .frame(height: 1)
                    .padding(.horizontal, 1)
            }
    }
}
