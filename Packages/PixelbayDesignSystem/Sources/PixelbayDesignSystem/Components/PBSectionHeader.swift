import SwiftUI

// Section header: a title in `sectionTitle` type with an optional trailing
// accessory (a button, count, toggle…). Used at the top of inspector panes and
// cards.

public struct PBSectionHeader<Accessory: View>: View {
    let title: String
    let accessory: Accessory

    public init(_ title: String, @ViewBuilder accessory: () -> Accessory) {
        self.title = title
        self.accessory = accessory()
    }

    public var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(Theme.Font.sectionTitle)
                .foregroundStyle(Theme.Color.textPrimary)
            Spacer(minLength: Theme.Spacing.sm)
            accessory
        }
    }
}

extension PBSectionHeader where Accessory == EmptyView {
    public init(_ title: String) {
        self.init(title) { EmptyView() }
    }
}
