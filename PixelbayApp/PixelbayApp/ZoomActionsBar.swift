import AVFoundation
import PixelbayCore
import PixelbayDesignSystem
import PixelbayEditor
import PixelbayInputCapture
import SwiftUI

// Quick zoom actions, surfaced on BOTH the Layout tab (for fast access while
// composing the frame) and the Zoom & Effects tab (above the keyframe list).
// Extracted out of `EffectsInspector` so the two surfaces share one
// implementation — the buttons, their busy state, the status line, and all the
// sidecar-aggregation generation logic live here.
//
// Three actions:
//   • Add Zoom at Playhead  — primary, always available (falls back to a
//     centred 0.5/0.5 anchor when there's no screen recording).
//   • From Pauses           — one zoom per cursor dwell (needs cursor telemetry).
//   • From Gestures         — one zoom per recorded shake / circle / ⌃⌘Z mark.
//
// All generation glue (reading the clicks sidecar, loading the recording's
// natural pixel size, shifting per-asset times onto the project timeline) is
// the same code that previously lived in EffectsInspector — moved verbatim.
struct ZoomActionsBar: View {
    let project: Project
    let bundleURL: URL
    /// Current playhead position in project-timeline seconds. Drives the
    /// "Add Zoom at Playhead" button so the inserted keyframe lands at the
    /// user's current scrub position.
    let playheadTime: Double
    let onApply: (any EditCommand) -> Void
    let onSeek: (RationalTime) -> Void

    @State private var isGeneratingPauses: Bool = false
    @State private var isGeneratingGestures: Bool = false
    @State private var isAddingZoom: Bool = false
    @State private var lastError: String?
    /// Set on a successful generate (e.g. "Generated 7 keyframes.").
    /// Mutually exclusive with `lastError` — every run clears both at the
    /// start, then writes one of them at the end. Drives the status row so
    /// the user sees something visibly happen on click.
    @State private var lastSuccess: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            addZoomButton
            HStack(spacing: Theme.Spacing.sm) {
                generatorTile(
                    title: "From Pauses",
                    systemImage: "cursorarrow.motionlines",
                    tint: Theme.Color.effectZoomAuto,
                    isBusy: isGeneratingPauses,
                    help: disabledReason ?? "Insert zoom keyframes where the cursor pauses."
                ) { Task { await generateAutoZoomFromPauses() } }

                generatorTile(
                    title: "From Gestures",
                    systemImage: "hand.draw",
                    tint: Theme.Color.effectZoomManual,
                    isBusy: isGeneratingGestures,
                    help: disabledReason ?? "Insert one zoom keyframe per recorded shake / circle / ⌃⌘Z mark."
                ) { Task { await generateZoomsFromGestures() } }
            }
            statusRow
        }
    }

    // MARK: - Buttons

    /// Primary action — accent-tinted, full-width. Unlike the two generators
    /// it works even without a screen recording, so it's never disabled by
    /// `canGenerate`.
    private var addZoomButton: some View {
        Button {
            Task { await addZoomAtPlayhead() }
        } label: {
            HStack(spacing: 6) {
                if isAddingZoom {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "plus.magnifyingglass")
                        .font(.system(size: 13, weight: .semibold))
                }
                Text(isAddingZoom ? "Adding…" : "Add Zoom at Playhead")
            }
            .font(Theme.Font.bodyEmphasized)
            .frame(maxWidth: .infinity)
            .frame(minHeight: 34)
            .foregroundStyle(Theme.Color.accent)
            .background(Theme.Color.accent.opacity(0.14))
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous)
                    .strokeBorder(Theme.Color.accent.opacity(0.32), lineWidth: Theme.Stroke.hairline)
            )
        }
        .buttonStyle(.plain)
        .disabled(anyGenerating)
        .opacity(isAddingZoom ? 0.7 : 1)
        .help("Insert one zoom keyframe at the current playhead position.")
    }

    /// Square-ish secondary tile: icon over a short label. Tinted icon ties
    /// the action to its timeline keyframe colour (indigo = auto, violet =
    /// gesture). Greys out when there's no usable clicks sidecar.
    private func generatorTile(
        title: String,
        systemImage: String,
        tint: Color,
        isBusy: Bool,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        let disabled = anyGenerating || !canGenerate
        return Button(action: action) {
            VStack(spacing: 6) {
                ZStack {
                    if isBusy {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: systemImage)
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(disabled ? Theme.Color.textTertiary : tint)
                    }
                }
                .frame(height: 18)
                Text(isBusy ? "Working…" : title)
                    .font(Theme.Font.caption)
                    .foregroundStyle(disabled ? Theme.Color.textTertiary : Theme.Color.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity)
            .frame(minHeight: 54)
            .background(Theme.Color.bgElevated)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous)
                    .strokeBorder(Theme.Color.borderSubtle, lineWidth: Theme.Stroke.hairline)
            )
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .help(help)
    }

    /// Always-visible status text below the buttons. Three states, in
    /// priority order: error (red) → success (blue) → disabled reason
    /// (secondary, explains why the generators are greyed).
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

    private var anyGenerating: Bool { isGeneratingPauses || isGeneratingGestures || isAddingZoom }

    // MARK: - Generate auto-zoom

    /// A `.display` MediaAsset paired with the screen clip(s) that reference
    /// it AND its on-disk clicks sidecar. Iterating over the list lets us
    /// aggregate clicks across every scene that recorded with click logging on.
    private struct AutoZoomPair {
        let asset: MediaAsset
        let clips: [Clip]
        let sidecarURL: URL
    }

    /// Returns every screen recording in this project that has BOTH a
    /// referencing clip AND a sidecar file on disk. Drives `canGenerate`
    /// and the multi-asset generate paths.
    private var availableAutoZoomPairs: [AutoZoomPair] {
        let screenAssetsByID: [MediaAssetID: MediaAsset] = Dictionary(
            project.assets
                .filter { $0.kind == .display }
                .map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
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

    private func generateAutoZoomFromPauses() async {
        guard !availableAutoZoomPairs.isEmpty else { return }
        isGeneratingPauses = true
        lastError = nil
        lastSuccess = nil
        defer { isGeneratingPauses = false }

        let aggregated = await aggregateAcrossPairs { sidecar, naturalSize -> ([AutoZoomClick], [MouseTrajectorySample]) in
            (
                [],
                AutoZoomService.mouseTrajectory(from: sidecar, screenPixelSize: naturalSize)
            )
        }

        if aggregated.trajectory.isEmpty {
            lastError = aggregated.firstError
                ?? "No cursor telemetry across this project's screen recordings."
            return
        }

        let manualZoomRanges = project.effects
            .filter { $0.kind == .zoom && $0.origin == .manualHotkey }
            .map(\.timelineRange)
        let duration = projectDuration ?? aggregated.trajectory.last?.timelineTime ?? 0
        let defaultDuration = EffectKeyframe.defaultZoomEaseIn.seconds
            + 1.8
            + EffectKeyframe.defaultZoomEaseOut.seconds
        let telemetry = aggregated.trajectory.map {
            CursorTelemetryPoint(
                timeMs: $0.timelineTime * 1000.0,
                cx: $0.centerX,
                cy: $0.centerY
            )
        }
        let autoClicks = AutoZoomService.dwellAutoZoomClicks(
            cursorTelemetry: telemetry,
            totalDuration: duration,
            existingRegions: manualZoomRanges,
            defaultDuration: defaultDuration
        )

        if autoClicks.isEmpty {
            lastError = "No cursor pauses long enough for auto-zoom."
            return
        }
        onApply(GenerateAutoZoomFromClicksCommand(
            clicks: autoClicks,
            timelineDuration: duration,
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

    /// "Add Zoom at Playhead" handler. Samples the master cursor trajectory
    /// at `playheadTime` to seed the zoom anchor; falls back to centre
    /// (0.5, 0.5) when no screen recording / sidecar is loaded.
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
        var didAnchorToCursor = false
        if !availableAutoZoomPairs.isEmpty {
            let aggregated = await aggregateAcrossPairs { sidecar, naturalSize -> ([AutoZoomClick], [MouseTrajectorySample]) in
                ([], AutoZoomService.mouseTrajectory(from: sidecar, screenPixelSize: naturalSize))
            }
            if let sample = nearestTrajectorySample(in: aggregated.trajectory, at: playheadTime) {
                anchorX = sample.centerX
                anchorY = sample.centerY
                didAnchorToCursor = true
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
        // read "Added zoom at playhead." on a rejected insert.
        if let reason = command.insertionConflict(in: project) {
            lastError = reason
            return
        }
        onApply(command)
        // Tell the user whether the zoom will track the cursor or sit
        // centered. The keyframe is always `.followCursor`, but it can only
        // follow if a master trajectory exists to re-slice onto it at
        // composition-build time — which requires the recording to have been
        // captured with cursor tracking on (the Precapture toggle).
        lastSuccess = didAnchorToCursor
            ? "Added zoom at playhead — follows cursor."
            : "Added zoom at playhead (centered). Record with cursor tracking on to follow the cursor."
        onSeek(.seconds(max(0, playheadTime)))
    }

    /// Total length of the project's timeline — `max(clip.timelineRange.end)`
    /// across all clips. Used as the upper bound for inserting a zoom at the
    /// playhead. Nil when the project is empty.
    private var projectDuration: Double? {
        let ends = project.tracks.flatMap(\.clips).map { $0.timelineRange.end.seconds }
        return ends.max()
    }

    /// Nearest trajectory sample to `time`. Linear scan — only runs on a user
    /// click (a handful of thousand samples max).
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

    /// Walk every `AutoZoomPair`, run `extract` on each loaded sidecar, shift
    /// the per-asset results onto the project timeline using each referencing
    /// clip's source/timeline ranges, then aggregate. The trajectory is
    /// returned sorted so EffectEvaluator's linear bracket scan picks the
    /// right neighbours across scene boundaries.
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

    /// Remap an `AutoZoomClick`'s recording-relative `timelineTime` onto the
    /// project timeline by mapping progress through the clip's `sourceRange`
    /// into its actual `timelineRange` (including speed changes). Lower-bound
    /// filter keeps clicks before a user-trimmed in-point out; no upper-bound
    /// filter (preserves single-shot parity with main — see the original
    /// EffectsInspector note).
    private func shiftClicks(_ clicks: [AutoZoomClick], into clip: Clip) -> [AutoZoomClick] {
        return clicks.compactMap { click in
            guard let timelineTime = timelineTime(forSourceTime: click.timelineTime, in: clip) else {
                return nil
            }
            return AutoZoomClick(
                timelineTime: timelineTime,
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
        return samples.compactMap { sample in
            guard let timelineTime = timelineTime(forSourceTime: sample.timelineTime, in: clip) else {
                return nil
            }
            return MouseTrajectorySample(
                timelineTime: timelineTime,
                centerX: sample.centerX,
                centerY: sample.centerY
            )
        }
    }

    private func timelineTime(forSourceTime sourceTime: Double, in clip: Clip) -> Double? {
        let sourceStart = clip.sourceRange.start.seconds
        guard sourceTime >= sourceStart else { return nil }
        let sourceDuration = clip.sourceRange.duration.seconds
        let timelineDuration = clip.timelineRange.duration.seconds
        guard sourceDuration > 0, timelineDuration > 0 else { return nil }
        let sourceProgress = (sourceTime - sourceStart) / sourceDuration
        return clip.timelineRange.start.seconds + sourceProgress * timelineDuration
    }

    private func loadSidecarAndSize(
        asset: MediaAsset,
        sidecarURL: URL
    ) async throws -> (ClicksSidecar, CGSize) {
        let sidecar = try ClicksSidecarStore.read(from: sidecarURL)
        let assetURL = try ProjectBundle(url: bundleURL).mediaURL(for: asset)
        let avAsset = AVURLAsset(url: assetURL)
        let videoTracks = try await avAsset.loadTracks(withMediaType: .video)
        guard let firstTrack = videoTracks.first else {
            throw NSError(
                domain: "ZoomActionsBar",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Screen recording has no video track."]
            )
        }
        let naturalSize = try await firstTrack.load(.naturalSize)
        return (sidecar, naturalSize)
    }
}
