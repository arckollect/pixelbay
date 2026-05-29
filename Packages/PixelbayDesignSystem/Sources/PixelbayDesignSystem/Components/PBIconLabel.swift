import SwiftUI

// SF Symbol + text row. Used in inspectors, defaults pickers, permission rows.
// Optional `detail` renders a secondary line under the title; `tint` colours
// the symbol (defaults to accent).

public struct PBIconLabel: View {
    let symbol: String
    let title: String
    let detail: String?
    let tint: Color

    public init(symbol: String, title: String, detail: String? = nil, tint: Color = Theme.Color.accent) {
        self.symbol = symbol
        self.title = title
        self.detail = detail
        self.tint = tint
    }

    public var body: some View {
        HStack(spacing: Theme.Spacing.md) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 22, alignment: .center)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(Theme.Font.bodyEmphasized)
                    .foregroundStyle(Theme.Color.textPrimary)
                if let detail {
                    Text(detail)
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.Color.textSecondary)
                }
            }
        }
    }
}
