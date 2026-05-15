import AVFoundation
import PixelbayCore
import PixelbayEditor
import PixelbayInputCapture
import SwiftUI

// Phase 3b Inspector section. Two halves:
//
// 1. Generate Auto-Zoom button. Glues AutoZoomService (pure helpers,
//    model-only) to disk I/O the service deliberately avoids: reading the
//    clicks sidecar via `ClicksSidecarStore.read(from:)` and loading the
//    screen recording's natural pixel size via AVURLAsset (mirrors
//    PreviewComposition's pattern at PreviewComposition.swift:233).
//    Disabled state has two reasons: no `.display` MediaAsset, or no
//    clicks sidecar on disk. Tooltip explains why it's grey.
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
    @Binding var selectedKeyframeID: EffectKeyframeID?
    let onApply: (any EditCommand) -> Void
    let onSeek: (RationalTime) -> Void

    @State private var isGenerating: Bool = false
    @State private var lastError: String?
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
        VStack(alignment: .leading, spacing: 8) {
            Text("Effects").font(.headline)
            generateButton
            if let lastError {
                Text(lastError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            Divider()
            keyframeList
            if let keyframe = selectedKeyframe {
                Divider()
                keyframeEditors(keyframe)
            }
        }
    }

    private var generateButton: some View {
        Button {
            Task { await generateAutoZoom() }
        } label: {
            if isGenerating {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Generating…")
                }
            } else {
                Label("Generate Auto-Zoom from Clicks", systemImage: "magnifyingglass.circle")
            }
        }
        .disabled(isGenerating || !canGenerate)
        .help(disabledReason ?? "Insert one zoom keyframe per logged click.")
    }

    @ViewBuilder
    private var keyframeList: some View {
        if sortedKeyframes.isEmpty {
            Text("No effects yet.")
                .font(.callout)
                .foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 2) {
                Text("Keyframes")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
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
        return HStack(spacing: 8) {
            Image(systemName: iconName(for: keyframe.kind))
                .foregroundStyle(isSelected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(HierarchicalShapeStyle.secondary))
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 0) {
                Text(label(for: keyframe.kind))
                    .font(.system(.caption, design: .default))
                Text(formatTime(keyframe.timelineRange.start.seconds))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                onApply(RemoveEffectKeyframeCommand(keyframeID: keyframe.id))
                if keyframe.id == selectedKeyframeID { selectedKeyframeID = nil }
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Remove effect")
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(isSelected ? Color.accentColor.opacity(0.18) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 4))
        .contentShape(Rectangle())
        .onTapGesture {
            selectedKeyframeID = keyframe.id
            onSeek(keyframe.timelineRange.start)
        }
    }

    private func keyframeEditors(_ keyframe: EffectKeyframe) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Selected effect")
                .font(.caption.bold())
                .foregroundStyle(.secondary)
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
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
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
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
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
                    .foregroundStyle(.secondary)
            }
            Slider(
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
        let updated = EffectKeyframe(
            id: keyframe.id,
            kind: keyframe.kind,
            timelineRange: keyframe.timelineRange,
            zoomFactor: newFactor,
            centerX: keyframe.centerX,
            centerY: keyframe.centerY,
            easeIn: keyframe.easeIn,
            easeOut: keyframe.easeOut,
            trajectory: keyframe.trajectory,
            extras: keyframe.extras
        )
        onApply(UpdateEffectKeyframeCommand(keyframeID: keyframeID, newValue: updated))
    }

    private func makeUpdated(
        _ keyframe: EffectKeyframe,
        start: RationalTime,
        duration: RationalTime
    ) -> EffectKeyframe {
        EffectKeyframe(
            id: keyframe.id,
            kind: keyframe.kind,
            timelineRange: TimeRange(start: start, duration: duration),
            zoomFactor: keyframe.zoomFactor,
            centerX: keyframe.centerX,
            centerY: keyframe.centerY,
            easeIn: keyframe.easeIn,
            easeOut: keyframe.easeOut,
            trajectory: keyframe.trajectory,
            extras: keyframe.extras
        )
    }

    // MARK: - Generate auto-zoom

    private var screenAsset: MediaAsset? {
        AutoZoomService.screenAsset(in: project)
    }

    private var sidecarURL: URL? {
        guard let asset = screenAsset else { return nil }
        return AutoZoomService.clicksSidecarURL(forScreenAsset: asset, in: bundleURL)
    }

    private var sidecarExists: Bool {
        guard let url = sidecarURL else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    private var canGenerate: Bool {
        screenAsset != nil && sidecarExists
    }

    private var disabledReason: String? {
        if screenAsset == nil { return "No screen recording in this project." }
        if !sidecarExists { return "No clicks sidecar — record with click logging enabled." }
        return nil
    }

    private func generateAutoZoom() async {
        guard let asset = screenAsset, let url = sidecarURL else { return }
        isGenerating = true
        lastError = nil
        defer { isGenerating = false }
        do {
            let sidecar = try ClicksSidecarStore.read(from: url)
            let assetURL = bundleURL.appendingPathComponent(asset.relativePath)
            let avAsset = AVURLAsset(url: assetURL)
            let videoTracks = try await avAsset.loadTracks(withMediaType: .video)
            guard let firstTrack = videoTracks.first else {
                lastError = "Screen recording has no video track."
                return
            }
            let naturalSize = try await firstTrack.load(.naturalSize)

            let trajectory = AutoZoomService.mouseTrajectory(
                from: sidecar,
                screenPixelSize: naturalSize
            )
            let optionalTrajectory: [MouseTrajectorySample]? = trajectory.isEmpty ? nil : trajectory

            // Auto trigger 1: filtered clicks (drop fast-movement clicks).
            let rawClicks = AutoZoomService.autoZoomClicks(
                from: sidecar,
                screenPixelSize: naturalSize
            )
            let filteredClicks = AutoZoomService.filterClicks(
                rawClicks,
                masterTrajectory: optionalTrajectory
            )
            // Auto trigger 2: cursor deceleration transitions.
            let decelClicks = AutoZoomService.decelerationZooms(from: optionalTrajectory)
            // Merge both trigger streams; the command's cluster pass dedupes.
            let autoClicks = (filteredClicks + decelClicks).sorted { $0.timelineTime < $1.timelineTime }

            // Manual marks: user-stated, bypass filter/cluster entirely.
            let marks = AutoZoomService.zoomMarks(from: sidecar, screenPixelSize: naturalSize)

            if autoClicks.isEmpty && marks.isEmpty {
                lastError = "No usable triggers in sidecar (all filtered, before capture start, or sidecar empty)."
                return
            }

            // Manual marks first so they get priority — the user explicitly
            // said "zoom here." Auto then fences clicks against any manual
            // ranges via its existing overlap-skip logic. Running auto first
            // would let auto-clusters occupy the timeline before manual got
            // a chance, causing GenerateManualZoomsCommand's occupied-range
            // check to drop gesture marks whose ramp overlaps a cluster.
            if !marks.isEmpty {
                onApply(GenerateManualZoomsCommand(
                    marks: marks,
                    mouseTrajectory: optionalTrajectory
                ))
            }
            if !autoClicks.isEmpty {
                onApply(GenerateAutoZoomFromClicksCommand(
                    clicks: autoClicks,
                    mouseTrajectory: optionalTrajectory
                ))
            }
        } catch {
            lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
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

    private func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00.00" }
        let minutes = Int(seconds) / 60
        let secs = seconds.truncatingRemainder(dividingBy: 60)
        return String(format: "%d:%05.2f", minutes, secs)
    }
}
