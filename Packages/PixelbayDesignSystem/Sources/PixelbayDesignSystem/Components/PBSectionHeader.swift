import SwiftUI

// Section header: a title with an optional trailing accessory (a button,
// count, toggle…). Two styles:
//
//   .title — `sectionTitle` type (17pt semibold), for page-level sections
//            (scenes window, onboarding panes).
//   .caps  — 11pt semibold small-caps-style secondary label, for dense
//            inspector panels where a 17pt header would shout. Reads like
//            the native macOS inspector group headers (Xcode, FCP).

public enum PBSectionHeaderStyle {
    case title
    case caps
}

public struct PBSectionHeader<Accessory: View>: View {
    let title: String
    let style: PBSectionHeaderStyle
    let accessory: Accessory

    public init(
        _ title: String,
        style: PBSectionHeaderStyle = .title,
        @ViewBuilder accessory: () -> Accessory
    ) {
        self.title = title
        self.style = style
        self.accessory = accessory()
    }

    public var body: some View {
        HStack(alignment: .firstTextBaseline) {
            switch style {
            case .title:
                Text(title)
                    .font(Theme.Font.sectionTitle)
                    .foregroundStyle(Theme.Color.textPrimary)
            case .caps:
                Text(title.uppercased())
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(0.6)
                    .foregroundStyle(Theme.Color.textSecondary)
            }
            Spacer(minLength: Theme.Spacing.sm)
            accessory
        }
    }
}

extension PBSectionHeader where Accessory == EmptyView {
    public init(_ title: String, style: PBSectionHeaderStyle = .title) {
        self.init(title, style: style) { EmptyView() }
    }
}
