import PixelbayCore
import PixelbayDesignSystem
import SwiftUI

// Cursor tab — the synthetic-cursor knobs (Phase 3c) carved out of
// LayoutInspector into their own inspector panel. Edits funnel back through
// owner-provided closures; the view stays a dumb form. Surfaces the synthetic
// cursor toggle, base size, zoom boost, and cursor blur in the dedicated Cursor
// tab instead of scattering cursor controls across Zoom & Effects.

struct CursorInspector: View {
    let cursorSettings: CursorSettings
    let tuningSettings: TuningSettings
    let onCursorChange: (CursorSettings) -> Void
    let onTuningChange: (TuningSettings) -> Void
    let onTuningPreview: (TuningSettings?) -> Void

    @State private var previewCursorScale: Double?
    @State private var previewCursorZoomBoost: Double?
    @State private var previewTuning: TuningSettings?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            PBSectionHeader("Cursor", style: .caps)
            enabledRow
            Group {
                cursorSizeSlider
                cursorZoomBoostSlider
                cursorBlurSlider
            }
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
        cursorSettingSlider(
            title: "Size",
            liveValue: previewCursorScale ?? cursorSettings.scale,
            committedValue: cursorSettings.scale,
            range: CursorSettings.scaleRange,
            valueText: { String(format: "%.2f×", $0) },
            currentPreview: { previewCursorScale },
            setPreview: { previewCursorScale = $0 },
            commit: { final in
                var next = cursorSettings
                next.scale = final
                onCursorChange(next)
            }
        )
    }

    private var cursorZoomBoostSlider: some View {
        cursorSettingSlider(
            title: "Zoom Size Boost",
            liveValue: previewCursorZoomBoost ?? cursorSettings.zoomScaleBoostPerZoomUnit,
            committedValue: cursorSettings.zoomScaleBoostPerZoomUnit,
            range: CursorSettings.zoomScaleBoostPerZoomUnitRange,
            valueText: { String(format: "%.2f×/zoom", $0) },
            currentPreview: { previewCursorZoomBoost },
            setPreview: { previewCursorZoomBoost = $0 },
            commit: { final in
                var next = cursorSettings
                next.zoomScaleBoostPerZoomUnit = final
                onCursorChange(next)
            }
        )
    }

    private var cursorBlurSlider: some View {
        let tuning = previewTuning ?? tuningSettings
        return cursorTuningSlider(
            title: "Motion Blur",
            tuning: tuning,
            keyPath: \.cursorBlur,
            range: TuningSettings.cursorBlurRange,
            valueText: { $0 <= 0.000_5 ? "Off" : percentText($0) }
        )
    }

    private func cursorSettingSlider(
        title: String,
        liveValue: Double,
        committedValue: Double,
        range: ClosedRange<Double>,
        valueText: @escaping (Double) -> String,
        currentPreview: @escaping () -> Double?,
        setPreview: @escaping (Double?) -> Void,
        commit: @escaping (Double) -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title).font(.caption)
                Spacer()
                Text(valueText(liveValue))
                    .font(Theme.Font.monoTimecode)
                    .foregroundStyle(Theme.Color.textSecondary)
            }
            PBSlider(
                value: Binding<Double>(
                    get: { liveValue },
                    set: { newValue in setPreview(clamp(newValue, to: range)) }
                ),
                in: range,
                onEditingChanged: { isEditing in
                    guard !isEditing else { return }
                    let final = clamp(currentPreview() ?? liveValue, to: range)
                    setPreview(nil)
                    guard abs(final - committedValue) >= 0.000_5 else { return }
                    commit(final)
                }
            )
        }
        .pbInsetRow()
    }

    private func cursorTuningSlider(
        title: String,
        tuning: TuningSettings,
        keyPath: WritableKeyPath<TuningSettings, Double>,
        range: ClosedRange<Double>,
        valueText: @escaping (Double) -> String
    ) -> some View {
        let liveValue = tuning[keyPath: keyPath]
        let committedValue = tuningSettings[keyPath: keyPath]
        return VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title).font(.caption)
                Spacer()
                Text(valueText(liveValue))
                    .font(Theme.Font.monoTimecode)
                    .foregroundStyle(Theme.Color.textSecondary)
            }
            PBSlider(
                value: Binding<Double>(
                    get: { liveValue },
                    set: { newValue in
                        var next = previewTuning ?? tuningSettings
                        next[keyPath: keyPath] = clamp(newValue, to: range)
                        previewTuning = next
                        onTuningPreview(next)
                    }
                ),
                in: range,
                onEditingChanged: { isEditing in
                    guard !isEditing else { return }
                    let final = previewTuning ?? tuningSettings
                    previewTuning = nil
                    onTuningPreview(nil)
                    guard abs(final[keyPath: keyPath] - committedValue) >= 0.000_5 else { return }
                    onTuningChange(final)
                }
            )
        }
        .pbInsetRow()
    }

    private func percentText(_ fraction: Double) -> String {
        String(format: "%d%%", Int((fraction * 100).rounded()))
    }

    private func clamp(_ value: Double, to range: ClosedRange<Double>) -> Double {
        min(max(value, range.lowerBound), range.upperBound)
    }
}
