import SwiftUI

// Card container modifier. `.pbCard()` wraps content in a rounded surface with
// a hairline border; `.pbCard(elevated: true)` uses the elevated surface for
// raised cards (defaults panels, permission rows). Padding is included so call
// sites don't re-pad.

public struct PBCardModifier: ViewModifier {
    let elevated: Bool
    let padding: CGFloat

    public func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(elevated ? Theme.Color.bgElevated : Theme.Color.bgInsetCard)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.large, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.large, style: .continuous)
                    .strokeBorder(Theme.Color.borderSubtle, lineWidth: Theme.Stroke.hairline)
            )
    }
}

extension View {
    public func pbCard(elevated: Bool = false, padding: CGFloat = Theme.Spacing.lg) -> some View {
        modifier(PBCardModifier(elevated: elevated, padding: padding))
    }
}
