import AVFoundation
import PixelbayCore
import PixelbayDesignSystem
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
    /// Current playhead position in project-timeline seconds. Drives the
    /// "Add Zoom at Playhead" button so the inserted keyframe lands at
    /// the user's current scrub position. Source: `PreviewPlayer.currentTime`
    /// in `ProjectView`.
    let playheadTime: Double
    @Binding var selectedKeyframeID: EffectKeyframeID?
    let onApply: (any EditCommand) -> Void
    let onSeek: (RationalTime) -> Void

    @State private var isGeneratingClicks: Bool = false
    @State private var isGeneratingGestures: Bool = false
    @State private var isAddingZoom: Bool = false
    @State private var lastError: String?
    /// Set on a successful generate (e.g. "Generated 7 keyframes.").
    /// Mutually exclusive with `lastError` — every generate run clears
    /// both at the start, then writes one of them at the end. Drives the
    /// status row so the user sees something visibly happen on click —
    /// the prior version only logged failures inline, so the success
    /// path was silent and users reported "click, nothing happens".
    @State private var lastSuccess: String?
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
            generateClicksButton
            generateGesturesButton
            addZoomButton
            statusRow
            PBDivider()
            keyframeList
            if let keyframe = selectedKeyframe {
                PBDivider()
                keyframeEditors(keyframe)
            }
        }
    }

    /// Always-visible status text below the generate buttons. Three
    /// states, in priority order:
    ///   1. `lastError` (red) — generate run threw or returned empty.
    ///   2. `lastSuccess` (secondary) — generate run produced keyframes.
    ///   3. `disabledReason` (secondary) — buttons are grayed out, this
    ///      explains why (no screen recording / no clicks sidecar) so
    ///      the user doesn't have to hover the tooltip.
    /// Always present so the user sees something visibly happen on
    /// click even when the run filtered everything out.
    @ViewBuilder
    private var statusRow: some View {
        if let lastError {
            Text(lastError)
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.Color.danger)
        } else if let lastSuccess {
            Text(lastSuccess)
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.Color.success)
        } else if let disabledReason {
            Text(disabledReason)
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.Color.textSecondary)
        }
    }

    private var anyGenerating: Bool { isGeneratingClicks || isGeneratingGestures || isAddingZoom }

    private var generateClicksButton: some View {
        Button {
            Task { await generateAutoZoomFromClicks() }
        } label: {
            if isGeneratingClicks {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Generating…")
                }
            } else {
                Label("Generate Auto-Zoom from Clicks", systemImage: "magnifyingglass.circle")
            }
        }
        .disabled(anyGenerating || !canGenerate)
        .help(disabledReason ?? "Insert one zoom keyframe per logged click.")
    }

    private var generateGesturesButton: some View {
        Button {
            Task { await generateZoomsFromGestures() }
        } label: {
            if isGeneratingGestures {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Generating…")
                }
            } else {
                Label("Generate Zooms from Gestures", systemImage: "hand.draw")
            }
        }
        .disabled(anyGenerating || !canGenerate)
        .help(disabledReason ?? "Insert one zoom keyframe per recorded shake / circle / ⌃⌘Z mark.")
    }

    /// "Add Zoom at Playhead" — hand-author a single zoom at the current
    /// scrub position. Unlike the two generators above, this works even
    /// without a screen recording (falls back to a centred 0.5/0.5 anchor);
    /// when a clicks sidecar IS present, the cursor position at the
    /// playhead seeds `centerX/centerY` so the zoom lands where the cursor
    /// actually is at that moment.
    private var addZoomButton: some View {
        Button {
            Task { await addZoomAtPlayhead() }
        } label: {
            if isAddingZoom {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Adding…")
                }
            } else {
                Label("Add Zoom at Playhead", systemImage: "plus.magnifyingglass")
            }
        }
        .disabled(anyGenerating)
        .help("Insert one zoom keyframe at the current playhead position.")
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

    // MARK: - Generate auto-zoom

    /// A `.display` MediaAsset paired with the screen clip(s) that
    /// reference it AND its on-disk clicks sidecar. Iterating over the
    /// list lets us aggregate clicks across every scene that recorded
    /// with click logging on — single-shot recordings produce one pair,
    /// scenes-merged projects produce one per scene's take.
    private struct AutoZoomPair {
        let asset: MediaAsset
        let clips: [Clip]
        let sidecarURL: URL
    }

    /// Returns every screen recording in this project that has BOTH a
    /// referencing clip AND a sidecar file on disk. Drives `canGenerate`
    /// and the multi-asset generate paths. Mirrors the pattern in
    /// `CursorTrajectoryLoader.screenClipsByAsset` so trajectories and
    /// clicks read the same set of sidecars.
    private var availableAutoZoomPairs: [AutoZoomPair] {
        let screenAssetsByID: [MediaAssetID: MediaAsset] = Dictionary(
            uniqueKeysWithValues: project.assets
                .filter { $0.kind == .display }
                .map { ($0.id, $0) }
        )
        var clipsByAsset: [MediaAssetID: [Clip]] = [:]
        for track in project.tracks where track.kind == .screen {
            for clip in track.clips where screenAssetsByID[clip.assetID] != nil {
                clipsByAsset[clip.assetID, default: []].append(clip)
            }
        }
        var pairs: [AutoZoomPair] = []
        for (id, clips) in clipsByAsset {
            guard let asset = screenAssetsByID[id] else { continue }
            guard let url = AutoZoomService.clicksSidecarURL(
                forScreenAsset: asset,
                in: bundleURL
            ) else { continue }
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            pairs.append(AutoZoomPair(asset: asset, clips: clips, sidecarURL: url))
        }
        return pairs
    }

    private var canGenerate: Bool { !availableAutoZoomPairs.isEmpty }

    private var disabledReason: String? {
        let hasScreenAsset = project.assets.contains(where: { $0.kind == .display })
        if !hasScreenAsset { return "No screen recording in this project." }
        let hasScreenClip = project.tracks
            .filter { $0.kind == .screen }
            .contains(where: { !$0.clips.isEmpty })
        if !hasScreenClip { return "Screen recording is not on the timeline." }
        if availableAutoZoomPairs.isEmpty {
            return "No clicks sidecar found — record with click logging enabled."
        }
        return nil
    }

    private func generateAutoZoomFromClicks() async {
        guard !availableAutoZoomPairs.isEmpty else { return }
        isGeneratingClicks = true
        lastError = nil
        lastSuccess = nil
        defer { isGeneratingClicks = false }

        let aggregated = await aggregateAcrossPairs { sidecar, naturalSize in
            (
                AutoZoomService.autoZoomClicks(from: sidecar, screenPixelSize: naturalSize),
                AutoZoomService.mouseTrajectory(from: sidecar, screenPixelSize: naturalSize)
            )
        }

        if aggregated.points.isEmpty {
            lastError = aggregated.firstError
                ?? "No usable clicks across this project's screen recordings."
            return
        }

        // Intent-scoring path. Trajectory passes through even when it spans
        // multiple scenes — IntentScorer does only local velocity calc
        // around each click.
        let candidates = IntentScorer.score(
            rawClicks: aggregated.points,
            trajectory: aggregated.trajectory
        )
        let autoClicks = IntentScorer.selectFiring(candidates)

        if autoClicks.isEmpty {
            lastError = "No usable clicks (all filtered or before capture start)."
            return
        }
        onApply(GenerateAutoZoomFromClicksCommand(
            clicks: autoClicks,
            mouseTrajectory: aggregated.trajectory.isEmpty ? nil : aggregated.trajectory
        ))
        lastSuccess = "Generated \(autoClicks.count) zoom keyframe\(autoClicks.count == 1 ? "" : "s")."
        if let first = autoClicks.first {
            onSeek(.seconds(first.timelineTime))
        }
    }

    private func generateZoomsFromGestures() async {
        guard !availableAutoZoomPairs.isEmpty else { return }
        isGeneratingGestures = true
        lastError = nil
        lastSuccess = nil
        defer { isGeneratingGestures = false }

        let aggregated = await aggregateAcrossPairs { sidecar, naturalSize in
            (
                AutoZoomService.zoomMarks(from: sidecar, screenPixelSize: naturalSize),
                AutoZoomService.mouseTrajectory(from: sidecar, screenPixelSize: naturalSize)
            )
        }

        if aggregated.points.isEmpty {
            lastError = aggregated.firstError
                ?? "No gesture marks found (record with gesture detection enabled)."
            return
        }
        onApply(GenerateManualZoomsCommand(
            marks: aggregated.points,
            mouseTrajectory: aggregated.trajectory.isEmpty ? nil : aggregated.trajectory
        ))
        lastSuccess = "Generated \(aggregated.points.count) zoom\(aggregated.points.count == 1 ? "" : "s") from gestures."
        if let first = aggregated.points.first {
            onSeek(.seconds(first.timelineTime))
        }
    }

    /// "Add Zoom at Playhead" handler. Samples the master cursor
    /// trajectory at `playheadTime` to seed the zoom anchor (so it lands
    /// on where the cursor actually is at that moment); falls back to
    /// centre (0.5, 0.5) when no screen recording / sidecar is loaded.
    /// The `AddZoomAtPlayheadCommand` itself bounds-checks against
    /// existing zooms and the timeline tail.
    private func addZoomAtPlayhead() async {
        isAddingZoom = true
        lastError = nil
        lastSuccess = nil
        defer { isAddingZoom = false }

        // Cursor anchor is best-effort: if there's no trajectory or the
        // sample lookup fails, default to centre. The user can still
        // re-anchor via the keyframe Stepper/sliders.
        var anchorX = 0.5
        var anchorY = 0.5
        if !availableAutoZoomPairs.isEmpty {
            let aggregated = await aggregateAcrossPairs { sidecar, naturalSize -> ([AutoZoomClick], [MouseTrajectorySample]) in
                ([], AutoZoomService.mouseTrajectory(from: sidecar, screenPixelSize: naturalSize))
            }
            if let sample = nearestTrajectorySample(in: aggregated.trajectory, at: playheadTime) {
                anchorX = sample.centerX
                anchorY = sample.centerY
            }
        }

        let timelineDuration = projectDuration
        let command = AddZoomAtPlayheadCommand(
            timelineTime: playheadTime,
            centerX: anchorX,
            centerY: anchorY,
            timelineDuration: timelineDuration
        )
        // Pre-check the same conflict `apply` throws on. `onApply` is
        // fire-and-forget (the document swallows the throw into its own
        // status banner), so without this the status row would falsely
        // read "Added zoom at playhead." on a rejected insert — and the
        // user would see a success message and a red error banner at once.
        if let reason = command.insertionConflict(in: project) {
            lastError = reason
            return
        }
        onApply(command)
        lastSuccess = "Added zoom at playhead."
        onSeek(.seconds(max(0, playheadTime)))
    }

    /// Total length of the project's timeline — `max(clip.timelineRange.end)`
    /// across all clips. Used as the upper bound for inserting a zoom at
    /// the playhead. Nil when the project is empty (no clips), in which
    /// case the insert command skips the upper-bound check.
    private var projectDuration: Double? {
        let ends = project.tracks.flatMap(\.clips).map { $0.timelineRange.end.seconds }
        return ends.max()
    }

    /// Nearest trajectory sample to `time`. The master is sorted by
    /// `timelineTime`, so a binary search would be more efficient; linear
    /// is fine here because this only runs on a user click (a handful of
    /// thousand samples max).
    private func nearestTrajectorySample(
        in samples: [MouseTrajectorySample],
        at time: Double
    ) -> MouseTrajectorySample? {
        guard !samples.isEmpty else { return nil }
        var best: MouseTrajectorySample?
        var bestDelta = Double.infinity
        for sample in samples {
            let delta = abs(sample.timelineTime - time)
            if delta < bestDelta {
                bestDelta = delta
                best = sample
            }
        }
        return best
    }

    /// Walk every `AutoZoomPair`, run `extract` on each loaded sidecar,
    /// shift the per-asset results onto the project timeline using each
    /// referencing clip's source/timeline ranges, then aggregate. The
    /// trajectory is returned sorted so EffectEvaluator's linear bracket
    /// scan picks the right neighbours across scene boundaries.
    private func aggregateAcrossPairs(
        _ extract: (ClicksSidecar, CGSize) -> ([AutoZoomClick], [MouseTrajectorySample])
    ) async -> AggregatedSidecarData {
        var points: [AutoZoomClick] = []
        var trajectory: [MouseTrajectorySample] = []
        var firstError: String?
        for pair in availableAutoZoomPairs {
            do {
                let (sidecar, naturalSize) = try await loadSidecarAndSize(
                    asset: pair.asset,
                    sidecarURL: pair.sidecarURL
                )
                let (perAssetPoints, perAssetTrajectory) = extract(sidecar, naturalSize)
                for clip in pair.clips {
                    points.append(contentsOf: shiftClicks(perAssetPoints, into: clip))
                    trajectory.append(contentsOf: shiftTrajectory(perAssetTrajectory, into: clip))
                }
            } catch {
                if firstError == nil {
                    firstError = (error as? LocalizedError)?.errorDescription
                        ?? error.localizedDescription
                }
                continue
            }
        }
        trajectory.sort { $0.timelineTime < $1.timelineTime }
        return AggregatedSidecarData(
            points: points,
            trajectory: trajectory,
            firstError: firstError
        )
    }

    private struct AggregatedSidecarData {
        let points: [AutoZoomClick]
        let trajectory: [MouseTrajectorySample]
        let firstError: String?
    }

    /// Remap an `AutoZoomClick`'s recording-relative `timelineTime` onto
    /// the project timeline by accounting for the clip's `sourceRange`
    /// (which part of the recording the clip uses) and `timelineRange`
    /// (where the clip sits in the project).
    ///
    /// Lower-bound filter (`>= sourceStart`) keeps clicks that fall
    /// before a user-trimmed in-point out of the timeline.
    ///
    /// No upper-bound filter: scenes-merged clips can have a tiny float
    /// gap between `clip.sourceRange.end` and the recording's actual
    /// last click (e.g. cam warmup makes the asset's nativeDuration
    /// slightly larger than the canonical scene duration, and
    /// ScenesMerger clamps the clip to the canonical value). The
    /// original main behavior had no upper bound either — clicks past
    /// the clip's end stayed in the keyframe set and the IntentScorer
    /// handled them. Preserving that here keeps single-shot recordings
    /// byte-identical to main and avoids the "No usable clicks across
    /// this project's screen recordings" false positive on borderline
    /// scenes-merged projects.
    private func shiftClicks(_ clicks: [AutoZoomClick], into clip: Clip) -> [AutoZoomClick] {
        let sourceStart = clip.sourceRange.start.seconds
        let timelineStart = clip.timelineRange.start.seconds
        return clicks.compactMap { click in
            guard click.timelineTime >= sourceStart else { return nil }
            return AutoZoomClick(
                timelineTime: timelineStart + (click.timelineTime - sourceStart),
                centerX: click.centerX,
                centerY: click.centerY,
                source: click.source
            )
        }
    }

    private func shiftTrajectory(
        _ samples: [MouseTrajectorySample],
        into clip: Clip
    ) -> [MouseTrajectorySample] {
        let sourceStart = clip.sourceRange.start.seconds
        let timelineStart = clip.timelineRange.start.seconds
        return samples.compactMap { sample in
            guard sample.timelineTime >= sourceStart else { return nil }
            return MouseTrajectorySample(
                timelineTime: timelineStart + (sample.timelineTime - sourceStart),
                centerX: sample.centerX,
                centerY: sample.centerY
            )
        }
    }

    private func loadSidecarAndSize(
        asset: MediaAsset,
        sidecarURL: URL
    ) async throws -> (ClicksSidecar, CGSize) {
        let sidecar = try ClicksSidecarStore.read(from: sidecarURL)
        let assetURL = bundleURL.appendingPathComponent(asset.relativePath)
        let avAsset = AVURLAsset(url: assetURL)
        let videoTracks = try await avAsset.loadTracks(withMediaType: .video)
        guard let firstTrack = videoTracks.first else {
            throw NSError(
                domain: "EffectsInspector",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Screen recording has no video track."]
            )
        }
        let naturalSize = try await firstTrack.load(.naturalSize)
        return (sidecar, naturalSize)
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
