import SwiftUI

// Hairline divider using `borderSubtle`. Horizontal by default; pass
// `.vertical` for a column separator.

public struct PBDivider: View {
    let axis: Axis

    public init(_ axis: Axis = .horizontal) {
        self.axis = axis
    }

    public var body: some View {
        Rectangle()
            .fill(Theme.Color.borderSubtle)
            .frame(
                width: axis == .vertical ? Theme.Stroke.hairline : nil,
                height: axis == .horizontal ? Theme.Stroke.hairline : nil
            )
    }
}
