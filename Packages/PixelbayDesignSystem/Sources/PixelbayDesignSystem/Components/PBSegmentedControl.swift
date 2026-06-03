import SwiftUI

// House-style segmented control — a custom replacement for SwiftUI's
// `Picker(...).pickerStyle(.segmented)`, which reads as the generic macOS
// system segmented control. Generic over the caller's `Tag` (usually an enum),
// so the existing inspector bindings drop in unchanged.
//
// Renders a `bgInsetCard` pill with a hairline border and an accent highlight
// that slides behind the selected label.

public struct PBSegmentedControl<Tag: Hashable>: View {
    public struct Segment: Identifiable {
        public let tag: Tag
        public let label: String
        public var id: Tag { tag }
        public init(tag: Tag, label: String) {
            self.tag = tag
            self.label = label
        }
    }

    @Binding private var selection: Tag
    private let segments: [Segment]

    public init(selection: Binding<Tag>, segments: [Segment]) {
        self._selection = selection
        self.segments = segments
    }

    private let height: CGFloat = 26
    private let inset: CGFloat = 2

    public var body: some View {
        GeometryReader { geo in
            let n = max(1, segments.count)
            let segW = geo.size.width / CGFloat(n)
            let selIdx = CGFloat(segments.firstIndex(where: { $0.tag == selection }) ?? 0)

            ZStack(alignment: .leading) {
                // Selected segment is a subtle RAISED neutral chip (not a loud
                // accent fill) — the premium Apple-native read. A hairline rim
                // + faint seating shadow lift it off the recessed track.
                RoundedRectangle(cornerRadius: Theme.Radius.small)
                    .fill(Theme.Color.bgElevated)
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.Radius.small)
                            .strokeBorder(Theme.Color.borderStrong, lineWidth: Theme.Stroke.hairline)
                    )
                    .shadow(color: .black.opacity(0.3), radius: 1.5, y: 0.5)
                    .frame(width: max(0, segW - inset * 2), height: max(0, geo.size.height - inset * 2))
                    .offset(x: selIdx * segW + inset)
                    .animation(.easeOut(duration: 0.15), value: selection)

                HStack(spacing: 0) {
                    ForEach(segments) { seg in
                        Text(seg.label)
                            .font(Theme.Font.bodyEmphasized)
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                            .foregroundStyle(seg.tag == selection ? Theme.Color.textPrimary : Theme.Color.textSecondary)
                            .frame(width: segW, height: geo.size.height)
                            .contentShape(Rectangle())
                            .onTapGesture { selection = seg.tag }
                    }
                }
            }
        }
        .frame(height: height)
        .background(Theme.Color.bgDeep)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.medium))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.medium)
                .strokeBorder(Theme.Color.borderSubtle, lineWidth: Theme.Stroke.hairline)
        )
    }
}

// Convenience for the common `[(tag, label)]` shape.
public extension PBSegmentedControl {
    init(selection: Binding<Tag>, _ pairs: [(Tag, String)]) {
        self.init(selection: selection, segments: pairs.map { Segment(tag: $0.0, label: $0.1) })
    }
}

#if DEBUG
private enum DemoTag: Hashable { case a, b, c }

#Preview {
    struct Harness: View {
        @State private var sel: DemoTag = .a
        var body: some View {
            PBSegmentedControl(selection: $sel, [
                (DemoTag.a, "Picture-in-Picture"),
                (DemoTag.b, "Side-by-Side"),
            ])
            .frame(width: 240)
            .padding(32)
            .background(Theme.Color.bgBase)
        }
    }
    return Harness()
}
#endif
