import PixelbayCore
import PixelbayDesignSystem
import SwiftUI

// Cursor tab — the synthetic-cursor knobs (Phase 3c) carved out of
// LayoutInspector into their own inspector panel. Edits funnel back through
// the single `onCursorChange` closure (dispatches SetCursorSettingsCommand);
// the view stays a dumb form. Surfaces `CursorSettings.isEnabled` as a real
// toggle (previously stored but never exposed) plus the size slider.

struct CursorInspector: View {
    let cursorSettings: CursorSettings
    let onCursorChange: (CursorSettings) -> Void

    // Live drag value for the size slider — the model is only mutated on
    // `onEditingChanged: false`, so the undo stack records one
    // SetCursorSettingsCommand per gesture instead of one per slider tick.
    @State private var previewCursorScale: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            PBSectionHeader("Cursor")
            enabledRow
            cursorSizeSlider
                .disabled(!cursorSettings.isEnabled)
                .opacity(cursorSettings.isEnabled ? 1 : 0.4)
        }
    }

    private var enabledRow: some View {
        HStack {
            Text("Synthetic Cursor")
                .font(Theme.Font.body)
                .foregroundStyle(Theme.Color.textPrimary)
            Spacer()
            Toggle("", isOn: Binding<Bool>(
                get: { cursorSettings.isEnabled },
                set: { newValue in
                    var next = cursorSettings
                    next.isEnabled = newValue
                    onCursorChange(next)
                }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .tint(Theme.Color.accent)
        }
    }

    private var cursorSizeSlider: some View {
        let liveValue = previewCursorScale ?? cursorSettings.scale
        let committedValue = cursorSettings.scale
        return VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("Size").font(.caption)
                Spacer()
                Text(String(format: "%.2f×", liveValue))
                    .font(Theme.Font.monoTimecode)
                    .foregroundStyle(Theme.Color.textSecondary)
            }
            Slider(
                value: Binding<Double>(
                    get: { liveValue },
                    set: { newValue in previewCursorScale = newValue }
                ),
                in: 0.5...4.0,
                onEditingChanged: { isEditing in
                    guard !isEditing, let final = previewCursorScale else { return }
                    previewCursorScale = nil
                    // Epsilon guard — sub-millimetre slider noise on
                    // release shouldn't write a no-op command to the
                    // undo stack.
                    if abs(final - committedValue) < 0.005 { return }
                    var next = cursorSettings
                    next.scale = final
                    onCursorChange(next)
                }
            )
        }
    }
}
