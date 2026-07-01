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
    let onFollowSafeZonePreview: (Double?) -> Void
    /// Live-drag tuning preview. Fired with the in-flight `TuningSettings`
    /// on every slider tick (the owner debounces and rebuilds just the
    /// videoComposition so the preview updates WHILE dragging), then with
    /// nil on release — the committed `SetTuningSettingsCommand` takes
    /// over from there.
    let onTuningPreview: (TuningSettings?) -> Void

    /// Drag-preview value for the zoom-factor slider. Mirrors the
    /// previewVolumes/previewSpeeds pattern in `ProjectView` — non-nil
    /// during a drag so the slider tracks live, then commits one
    /// `UpdateEffectKeyframeCommand` on mouse-up.
    @State private var previewZoomFactor: Double?
    @State private var previewEaseIn: Double?
    @State private var previewEaseOut: Double?
    /// Drag-preview copy of the project's motion tuning. Non-nil while any
    /// tuning slider is mid-drag; one `SetTuningSettingsCommand` commits on
    /// mouse-up so the undo stack gets one entry per gesture.
    @State private var previewTuning: TuningSettings?
    /// Brief "copied" affordance on the Copy Values button.
    @State private var didCopyTuning = false

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
            motionTuningSection
            PBDivider()
            keyframeList
            if let keyframe = selectedKeyframe {
                PBDivider()
                keyframeEditors(keyframe)
            }
        }
        .onDisappear {
            onFollowSafeZonePreview(nil)
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
                easingSection(keyframe)
                zoomKeyframeAdvancedSection(keyframe)
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

    private func easingSection(_ keyframe: EffectKeyframe) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Easing")
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.Color.textSecondary)
            easeSlider(
                title: "In",
                liveValue: previewEaseIn ?? keyframe.easeIn.seconds,
                committedValue: keyframe.easeIn.seconds,
                upperBound: easeUpperBound(for: keyframe),
                currentPreview: { previewEaseIn },
                setPreview: { previewEaseIn = $0 },
                commit: { final in commitEaseIn(keyframe: keyframe, seconds: final) }
            )
            easeSlider(
                title: "Out",
                liveValue: previewEaseOut ?? keyframe.easeOut.seconds,
                committedValue: keyframe.easeOut.seconds,
                upperBound: easeUpperBound(for: keyframe),
                currentPreview: { previewEaseOut },
                setPreview: { previewEaseOut = $0 },
                commit: { final in commitEaseOut(keyframe: keyframe, seconds: final) }
            )
        }
    }

    // MARK: - Motion Tuning

    /// Reference-style motion controls. The zoom follow constants now live in
    /// `ZoomMotionConstants`; the inspector only exposes the authored zoom
    /// transition and the two blur amounts that remain user-facing.
    private var motionTuningSection: some View {
        let tuning = previewTuning ?? project.tuning
        return VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            HStack(spacing: Theme.Spacing.sm) {
                Text("Motion")
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.Color.textSecondary)
                Spacer()
                if tuning != TuningSettings.default {
                    Button {
                        commitTuning(.default)
                    } label: {
                        Image(systemName: "arrow.counterclockwise")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.Color.textTertiary)
                    .help("Reset motion settings")
                }
            }

            tuningGroup("Zoom") {
                tuningSlider("Transition Softness", tuning, \.transitionSoftness, TuningSettings.transitionSoftnessRange) { percentText($0) }
            }

            tuningGroup("Motion Blur") {
                tuningSlider("Screen", tuning, \.blurStrength, TuningSettings.blurStrengthRange) {
                    $0 <= 0.000_5 ? "Off" : String(format: "%.2f", $0)
                }
            }
        }
    }

    private func tuningGroup(
        _ title: String,
        @ViewBuilder content: () -> some View
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased())
                .font(Theme.Font.caption)
                .kerning(0.6)
                .foregroundStyle(Theme.Color.textTertiary)
            content()
        }
        .padding(Theme.Spacing.sm)
        .background(
            Theme.Color.bgInsetCard,
            in: RoundedRectangle(cornerRadius: Theme.Radius.medium)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.medium)
                .stroke(Theme.Color.borderSubtle, lineWidth: 1)
        )
    }

    private func smoothingScopePicker(_ tuning: TuningSettings) -> some View {
        HStack {
            Text("Smooth")
            Spacer()
            Picker("", selection: Binding<SmoothingScope>(
                get: { tuning.smoothingScope },
                set: { newScope in
                    var next = project.tuning
                    next.smoothingScope = newScope
                    commitTuning(next)
                }
            )) {
                Text("Everywhere").tag(SmoothingScope.fullRecording)
                Text("Zooms Only").tag(SmoothingScope.zoomsOnly)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 180)
        }
    }

    private func tuningSlider(
        _ title: String,
        _ tuning: TuningSettings,
        _ keyPath: WritableKeyPath<TuningSettings, Double>,
        _ range: ClosedRange<Double>,
        onDrag: ((Double?) -> Void)? = nil,
        valueText: @escaping (Double) -> String
    ) -> some View {
        let liveValue = tuning[keyPath: keyPath]
        let committedValue = project.tuning[keyPath: keyPath]
        return VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                Spacer()
                Text(valueText(liveValue))
                    .font(Theme.Font.monoTimecode)
                    .foregroundStyle(Theme.Color.textSecondary)
            }
            PBSlider(
                value: Binding<Double>(
                    get: { liveValue },
                    set: { newValue in
                        var next = previewTuning ?? project.tuning
                        next[keyPath: keyPath] = clamp(newValue, to: range)
                        previewTuning = next
                        onDrag?(next[keyPath: keyPath])
                        onTuningPreview(next)
                    }
                ),
                in: range,
                onEditingChanged: { isEditing in
                    guard !isEditing else { return }
                    let final = previewTuning ?? project.tuning
                    previewTuning = nil
                    onDrag?(nil)
                    onTuningPreview(nil)
                    guard abs(final[keyPath: keyPath] - committedValue) >= 0.000_5 else { return }
                    commitTuning(final)
                }
            )
        }
    }

    private func commitTuning(_ tuning: TuningSettings) {
        guard tuning != project.tuning else { return }
        onApply(SetTuningSettingsCommand(newSettings: tuning))
    }

    private func msText(_ seconds: Double) -> String {
        String(format: "%dms", Int((seconds * 1000).rounded()))
    }

    private func percentText(_ fraction: Double) -> String {
        String(format: "%d%%", Int((fraction * 100).rounded()))
    }

    private func zoomKeyframeAdvancedSection(_ keyframe: EffectKeyframe) -> some View {
        DisclosureGroup {
            centerCursorToggle(keyframe)
                .padding(.top, 2)
        } label: {
            Text("Advanced")
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.Color.textSecondary)
        }
    }

    private func centerCursorToggle(_ keyframe: EffectKeyframe) -> some View {
        HStack {
            Text("Center Cursor")
            Spacer()
            Toggle("", isOn: Binding<Bool>(
                get: { keyframe.anchorMode == .centerCursor },
                set: { enabled in
                    var updated = keyframe
                    updated.anchorMode = enabled ? .centerCursor : .followCursor
                    onApply(UpdateEffectKeyframeCommand(keyframeID: keyframe.id, newValue: updated))
                }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .tint(Theme.Color.accent)
        }
    }

    private func easeSlider(
        title: String,
        liveValue: Double,
        committedValue: Double,
        upperBound: Double,
        currentPreview: @escaping () -> Double?,
        setPreview: @escaping (Double?) -> Void,
        commit: @escaping (Double) -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                Spacer()
                Text(String(format: "%.2fs", liveValue))
                    .font(Theme.Font.monoTimecode)
                    .foregroundStyle(Theme.Color.textSecondary)
            }
            PBSlider(
                value: Binding<Double>(
                    get: { liveValue },
                    set: { newValue in setPreview(min(max(newValue, 0), upperBound)) }
                ),
                in: 0.0...upperBound,
                onEditingChanged: { isEditing in
                    guard !isEditing else { return }
                    let final = min(max(currentPreview() ?? liveValue, 0), upperBound)
                    setPreview(nil)
                    guard abs(final - committedValue) >= 0.005 else { return }
                    commit(final)
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

    private func commitEaseIn(keyframe: EffectKeyframe, seconds: Double) {
        var updated = keyframe
        updated.easeIn = .seconds(max(0, seconds))
        onApply(UpdateEffectKeyframeCommand(keyframeID: keyframe.id, newValue: updated))
    }

    private func commitEaseOut(keyframe: EffectKeyframe, seconds: Double) {
        var updated = keyframe
        updated.easeOut = .seconds(max(0, seconds))
        onApply(UpdateEffectKeyframeCommand(keyframeID: keyframe.id, newValue: updated))
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

    private func easeUpperBound(for keyframe: EffectKeyframe) -> Double {
        max(
            0.1,
            keyframe.timelineRange.duration.seconds,
            keyframe.easeIn.seconds,
            keyframe.easeOut.seconds
        )
    }

    private func shutterText(_ seconds: Double) -> String {
        guard seconds > 0 else { return "0" }
        return String(format: "1/%d", Int((1.0 / seconds).rounded()))
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

    private func clamp(_ value: Double, to range: ClosedRange<Double>) -> Double {
        min(max(value, range.lowerBound), range.upperBound)
    }
}
