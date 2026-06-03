import SwiftUI

// A Screen-Studio-style inspector chrome: a content panel with a thin
// vertical strip of icon tabs pinned to its trailing (far-right) edge.
// The active tab tints to `accent` and grows a 2pt trailing indicator
// capsule; the rest sit quiet in `textSecondary` and lift to `textPrimary`
// on hover.
//
// Generic over the caller's tab `Tag` (any Hashable — usually an enum) so
// selection state lives with the caller and can interact with other editor
// state (e.g. auto-switching tabs on a timeline selection). The `content`
// builder is handed the active tag and returns that tab's panel; panels
// own their own scrolling/padding so this component stays pure chrome.

public struct PBTabItem<Tag: Hashable>: Identifiable {
    public let tag: Tag
    public let systemImage: String
    public let help: String

    public var id: Tag { tag }

    public init(tag: Tag, systemImage: String, help: String) {
        self.tag = tag
        self.systemImage = systemImage
        self.help = help
    }
}

public struct PBVerticalTabRail<Tag: Hashable, Content: View>: View {
    private let tabs: [PBTabItem<Tag>]
    @Binding private var selection: Tag
    private let railWidth: CGFloat
    private let content: (Tag) -> Content

    @State private var hoveredTag: Tag?

    public init(
        tabs: [PBTabItem<Tag>],
        selection: Binding<Tag>,
        railWidth: CGFloat = 44,
        @ViewBuilder content: @escaping (Tag) -> Content
    ) {
        self.tabs = tabs
        self._selection = selection
        self.railWidth = railWidth
        self.content = content
    }

    public var body: some View {
        HStack(spacing: 0) {
            content(selection)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(Theme.Color.bgDeep)

            PBDivider(.vertical)

            iconStrip
        }
    }

    private var iconStrip: some View {
        VStack(spacing: Theme.Spacing.xs) {
            ForEach(tabs) { tab in
                tabButton(tab)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, Theme.Spacing.sm)
        .frame(width: railWidth)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Theme.Color.bgBase)
    }

    private func tabButton(_ tab: PBTabItem<Tag>) -> some View {
        let isSelected = tab.tag == selection
        let isHovered = tab.tag == hoveredTag
        let tint: Color = isSelected
            ? Theme.Color.accent
            : (isHovered ? Theme.Color.textPrimary : Theme.Color.textSecondary)

        return Button {
            selection = tab.tag
        } label: {
            Image(systemName: tab.systemImage)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 32, height: 32)
                .background(
                    RoundedRectangle(cornerRadius: Theme.Radius.medium)
                        .fill(isSelected ? Theme.Color.accent.opacity(0.15) : Color.clear)
                )
                .overlay(alignment: .leading) {
                    // Screen-Studio active indicator: a short accent capsule
                    // riding the strip's inner edge (the side facing the
                    // content panel) of the selected tab. The button label is
                    // a 32pt frame centred in `railWidth`, so the gap to the
                    // strip edge is (railWidth - 32) / 2 — offset by that so
                    // the capsule lands on the edge, in-bounds.
                    if isSelected {
                        Capsule()
                            .fill(Theme.Color.accent)
                            .frame(width: 2, height: 18)
                            .offset(x: -((railWidth - 32) / 2))
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(tab.help)
        .onHover { hovering in
            hoveredTag = hovering ? tab.tag : (hoveredTag == tab.tag ? nil : hoveredTag)
        }
    }
}

#if DEBUG
private enum PreviewTab: Hashable { case one, two, three }

#Preview {
    struct Harness: View {
        @State private var sel: PreviewTab = .one
        var body: some View {
            PBVerticalTabRail(
                tabs: [
                    PBTabItem(tag: .one, systemImage: "rectangle.on.rectangle", help: "Layout"),
                    PBTabItem(tag: .two, systemImage: "cursorarrow.rays", help: "Cursor"),
                    PBTabItem(tag: .three, systemImage: "speaker.wave.2", help: "Audio")
                ],
                selection: $sel
            ) { tab in
                VStack(alignment: .leading) {
                    Text("Panel: \(String(describing: tab))")
                        .font(Theme.Font.sectionTitle)
                        .foregroundStyle(Theme.Color.textPrimary)
                    Spacer()
                }
                .padding()
            }
            .frame(width: 360, height: 480)
        }
    }
    return Harness()
}
#endif
