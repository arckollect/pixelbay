import SwiftUI

// House-style text-field chrome — replaces `.textFieldStyle(.roundedBorder)`,
// which is the most obviously OS-default control in the editor. Apply to a
// `TextField` (keep its own `.focused`/`.onSubmit`/`.onChange`): pass the field's
// focus state so the border tints to accent while editing.
//
//   TextField("Name", text: $name)
//       .focused($editing)
//       .pbField(focused: editing)

public extension View {
    func pbField(focused: Bool = false) -> some View {
        self
            .textFieldStyle(.plain)
            .font(Theme.Font.body)
            .foregroundStyle(Theme.Color.textPrimary)
            .padding(.horizontal, Theme.Spacing.sm)
            .padding(.vertical, 6)
            .background(Theme.Color.bgInsetCard)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.medium))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.medium)
                    .strokeBorder(
                        focused ? Theme.Color.accent : Theme.Color.borderSubtle,
                        lineWidth: focused ? Theme.Stroke.regular : Theme.Stroke.hairline
                    )
            )
            .animation(.easeOut(duration: 0.12), value: focused)
    }
}
