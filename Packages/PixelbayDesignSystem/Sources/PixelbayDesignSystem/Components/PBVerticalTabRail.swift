import SwiftUI

// A Screen-Studio-style inspector chrome: a content panel with a vertical
// strip of tabs pinned to its trailing (far-right) edge. Tabs render as
// icon-over-label chips (label optional — omit `title` for icon-only).
// The active tab tints to `accent` on a soft accent chip and grows a 2pt
// trailing indicator capsule; the rest sit quiet in `textSecondary` and
// lift to `textPrimary` on a `bgElevated` wash on hover.
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
    /// Short caption rendered under the icon (e.g. "Layout"). nil → icon-only
    /// tab (the original rail look) with `help` still available as a tooltip.
    public let title: String?

    public var id: Tag { tag }

    public init(tag: Tag, systemImage: String, help: String, title: String? = nil) {
        self.tag = tag
        self.systemImage = systemImage
        self.help = help
        self.title = title
    }
}

public struct PBVerticalTabRail<Tag: Hashable, Content: View>: View {
    private let tabs: [PBTabItem<Tag>]
    @Binding private var selection: Tag
    private let railWidth: CGFloat
    private let content: (Tag) -> Content

    @State private var hoveredTag: Tag?

    /// Whether any tab carries a title — labeled tabs need a wider rail and
    /// taller chips, so the geometry switches as a set.
    private var isLabeled: Bool { tabs.contains { $0.title != nil } }

    public init(
        tabs: [PBTabItem<Tag>],
        selection: Binding<Tag>,
        railWidth: CGFloat? = nil,
        @ViewBuilder content: @escaping (Tag) -> Content
    ) {
        self.tabs = tabs
        self._selection = selection
        self.railWidth = railWidth ?? (tabs.contains { $0.title != nil } ? 64 : 44)
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

    /// Chip width inside the rail; the remaining gutter splits evenly, which
    /// the selection capsule offset below depends on.
    private var chipWidth: CGFloat { railWidth - 12 }

    private func tabButton(_ tab: PBTabItem<Tag>) -> some View {
        let isSelected = tab.tag == selection
        let isHovered = tab.tag == hoveredTag
        let tint: Color = isSelected
            ? Theme.Color.accent
            : (isHovered ? Theme.Color.textPrimary : Theme.Color.textSecondary)

        return Button {
            selection = tab.tag
        } label: {
            VStack(spacing: 3) {
                Image(systemName: tab.systemImage)
                    .font(.system(size: 15, weight: .medium))
                if let title = tab.title {
                    Text(title)
                        .font(.system(size: 9, weight: .medium))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
            }
            .foregroundStyle(tint)
            .frame(width: chipWidth, height: isLabeled ? 44 : 32)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.medium)
                    .fill(chipFill(selected: isSelected, hovered: isHovered))
            )
            .overlay(alignment: .leading) {
                // Screen-Studio active indicator: a short accent capsule
                // riding the strip's inner edge (the side facing the
                // content panel) of the selected tab. The chip is centred
                // in `railWidth`, so the gap to the strip edge is
                // (railWidth - chipWidth) / 2 — offset by that so the
                // capsule lands on the edge, in-bounds.
                if isSelected {
                    Capsule()
                        .fill(Theme.Color.accent)
                        .frame(width: 2, height: isLabeled ? 24 : 18)
                        .offset(x: -((railWidth - chipWidth) / 2))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(tab.help)
        .animation(.easeOut(duration: 0.12), value: isHovered)
        .onHover { hovering in
            hoveredTag = hovering ? tab.tag : (hoveredTag == tab.tag ? nil : hoveredTag)
        }
    }

    private func chipFill(selected: Bool, hovered: Bool) -> Color {
        if selected { return Theme.Color.accent.opacity(0.15) }
        if hovered { return Theme.Color.bgElevated }
        return .clear
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
                    PBTabItem(tag: .one, systemImage: "rectangle.on.rectangle", help: "Layout", title: "Layout"),
                    PBTabItem(tag: .two, systemImage: "cursorarrow.rays", help: "Cursor", title: "Cursor"),
                    PBTabItem(tag: .three, systemImage: "speaker.wave.2", help: "Audio", title: "Audio")
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
            .frame(width: 380, height: 480)
        }
    }
    return Harness()
}
#endif
