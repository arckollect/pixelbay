import PixelbayCore
import PixelbayDesignSystem
import PixelbayEditor
import SwiftUI

// Phase 3b Inspector section. Two halves:
//
// 1. `ZoomActionsBar` — the Add / From-Clicks / From-Gestures buttons plus
//    their status line. This is a shared component (it also appears on the
//    Layout tab for quick access); all the sidecar-aggregation generation
//    logic lives there.
//
// 2. Keyframe list + editors. Bound to `selectedEffectKeyframeID` so
//    timeline-side and inspector-side selection stay in sync. Clicking a
//    row also jumps the playhead to that keyframe's start (timeline
//    clicks don't seek — only inspector clicks do, because the inspector
//    is the navigation surface). The selected row exposes start /
//    duration steppers and a zoom-factor slider (zoom kind only). All
//    edits dispatch `UpdateEffectKeyframeCommand`; delete dispatches
//    `RemoveEffectKeyframeCommand`.

struct EffectsInspector: View {
    let project: Project
    let bundleURL: URL
    /// Current playhead position in project-timeline seconds. Forwarded to
    /// `ZoomActionsBar` so "Add Zoom at Playhead" lands at the user's scrub
    /// position. Source: `PreviewPlayer.currentTime` in `ProjectView`.
    let playheadTime: Double
    @Binding var selectedKeyframeID: EffectKeyframeID?
    let onApply: (any EditCommand) -> Void
    let onSeek: (RationalTime) -> Void

    /// Drag-preview value for the zoom-factor slider. Mirrors the
    /// previewVolumes/previewSpeeds pattern in `ProjectView` — non-nil
    /// during a drag so the slider tracks live, then commits one
    /// `UpdateEffectKeyframeCommand` on mouse-up.
    @State private var previewZoomFactor: Double?

    private var sortedKeyframes: [EffectKeyframe] {
        project.effects.sorted { $0.timelineRange.start.seconds < $1.timelineRange.start.seconds }
    }

    private var selectedKeyframe: EffectKeyframe? {
        guard let id = selectedKeyframeID else { return nil }
        return project.effects.first(where: { $0.id == id })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            PBSectionHeader("Effects")
            ZoomActionsBar(
                project: project,
                bundleURL: bundleURL,
                playheadTime: playheadTime,
                onApply: onApply,
                onSeek: onSeek
            )
            PBDivider()
            keyframeList
            if let keyframe = selectedKeyframe {
                PBDivider()
                keyframeEditors(keyframe)
            }
        }
    }

    @ViewBuilder
    private var keyframeList: some View {
        if sortedKeyframes.isEmpty {
            Text("No effects yet.")
                .font(Theme.Font.body)
                .foregroundStyle(Theme.Color.textSecondary)
        } else {
            VStack(alignment: .leading, spacing: 2) {
                Text("Keyframes")
                    .font(Theme.Font.cardTitle)
                    .foregroundStyle(Theme.Color.textSecondary)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(sortedKeyframes) { keyframe in
                            keyframeRow(keyframe)
                        }
                    }
                }
                .frame(maxHeight: 140)
            }
        }
    }

    private func keyframeRow(_ keyframe: EffectKeyframe) -> some View {
        let isSelected = keyframe.id == selectedKeyframeID
        return HStack(spacing: Theme.Spacing.sm) {
            Image(systemName: iconName(for: keyframe.kind))
                .foregroundStyle(isSelected ? Theme.Color.accent : Theme.Color.textSecondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 0) {
                Text(label(for: keyframe.kind))
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.Color.textPrimary)
                Text(Timecode.precise(keyframe.timelineRange.start.seconds))
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.Color.textSecondary)
            }
            Spacer()
            Button {
                onApply(RemoveEffectKeyframeCommand(keyframeID: keyframe.id))
                if keyframe.id == selectedKeyframeID { selectedKeyframeID = nil }
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.Color.textTertiary)
            .help("Remove effect")
        }
        .padding(.horizontal, Theme.Spacing.sm)
        .padding(.vertical, Theme.Spacing.xs)
        .background(isSelected ? Theme.Color.accent.opacity(0.18) : Color.clear,
                    in: RoundedRectangle(cornerRadius: Theme.Radius.small))
        .contentShape(Rectangle())
        .onTapGesture {
            selectedKeyframeID = keyframe.id
            onSeek(keyframe.timelineRange.start)
        }
    }

    private func keyframeEditors(_ keyframe: EffectKeyframe) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Text("Selected effect")
                .font(Theme.Font.cardTitle)
                .foregroundStyle(Theme.Color.textSecondary)
            startStepper(keyframe)
            durationStepper(keyframe)
            if keyframe.kind == .zoom {
                zoomFactorSlider(keyframe)
            }
        }
    }

    private func startStepper(_ keyframe: EffectKeyframe) -> some View {
        let value = keyframe.timelineRange.start.seconds
        return HStack {
            Text("Start")
            Spacer()
            Text(String(format: "%.2fs", value))
                .font(Theme.Font.monoTimecode)
                .foregroundStyle(Theme.Color.textSecondary)
            Stepper("", value: Binding<Double>(
                get: { value },
                set: { newValue in commitStart(keyframe: keyframe, newStart: max(0, newValue)) }
            ), step: 0.05)
            .labelsHidden()
        }
    }

    private func durationStepper(_ keyframe: EffectKeyframe) -> some View {
        let value = keyframe.timelineRange.duration.seconds
        return HStack {
            Text("Duration")
            Spacer()
            Text(String(format: "%.2fs", value))
                .font(Theme.Font.monoTimecode)
                .foregroundStyle(Theme.Color.textSecondary)
            Stepper("", value: Binding<Double>(
                get: { value },
                set: { newValue in commitDuration(keyframe: keyframe, newDuration: max(0.05, newValue)) }
            ), step: 0.05)
            .labelsHidden()
        }
    }

    private func zoomFactorSlider(_ keyframe: EffectKeyframe) -> some View {
        let liveValue = previewZoomFactor ?? keyframe.zoomFactor
        let committedValue = keyframe.zoomFactor
        let keyframeID = keyframe.id
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Zoom")
                Spacer()
                Text(String(format: "%.2f×", liveValue))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(Theme.Color.textSecondary)
            }
            PBSlider(
                value: Binding<Double>(
                    get: { liveValue },
                    set: { newValue in previewZoomFactor = newValue }
                ),
                in: 1.0...3.0,
                onEditingChanged: { isEditing in
                    guard !isEditing, let final = previewZoomFactor else { return }
                    previewZoomFactor = nil
                    if abs(final - committedValue) < 0.001 { return }
                    commitZoomFactor(keyframe: keyframe, newFactor: final, keyframeID: keyframeID)
                }
            )
        }
    }

    // MARK: - Commit helpers

    private func commitStart(keyframe: EffectKeyframe, newStart: Double) {
        guard abs(newStart - keyframe.timelineRange.start.seconds) > 0.001 else { return }
        let updated = makeUpdated(
            keyframe,
            start: .seconds(newStart),
            duration: keyframe.timelineRange.duration
        )
        onApply(UpdateEffectKeyframeCommand(keyframeID: keyframe.id, newValue: updated))
    }

    private func commitDuration(keyframe: EffectKeyframe, newDuration: Double) {
        guard abs(newDuration - keyframe.timelineRange.duration.seconds) > 0.001 else { return }
        let updated = makeUpdated(
            keyframe,
            start: keyframe.timelineRange.start,
            duration: .seconds(newDuration)
        )
        onApply(UpdateEffectKeyframeCommand(keyframeID: keyframe.id, newValue: updated))
    }

    private func commitZoomFactor(keyframe: EffectKeyframe, newFactor: Double, keyframeID: EffectKeyframeID) {
        var updated = keyframe
        updated.zoomFactor = newFactor
        onApply(UpdateEffectKeyframeCommand(keyframeID: keyframeID, newValue: updated))
    }

    private func makeUpdated(
        _ keyframe: EffectKeyframe,
        start: RationalTime,
        duration: RationalTime
    ) -> EffectKeyframe {
        var updated = keyframe
        updated.timelineRange = TimeRange(start: start, duration: duration)
        return updated
    }

    // MARK: - Formatting

    private func iconName(for kind: EffectKind) -> String {
        switch kind {
        case .zoom: return "magnifyingglass.circle.fill"
        case .talkingHeadSwap: return "person.crop.rectangle.fill"
        }
    }

    private func label(for kind: EffectKind) -> String {
        switch kind {
        case .zoom: return "Zoom"
        case .talkingHeadSwap: return "Talking head"
        }
    }
}
