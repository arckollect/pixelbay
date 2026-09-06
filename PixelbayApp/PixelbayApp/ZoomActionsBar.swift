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
// Four actions:
//   • Add Zoom at Playhead         — primary, always available (falls back to
//     a centred 0.5/0.5 anchor when there's no screen recording).
//   • Add Talking Head at Playhead — webcam full-frame for a few seconds
//     (needs a webcam track; the timeline has no separate webcam row).
//   • From Pauses                  — one zoom per cursor dwell (needs cursor telemetry).
//   • From Gestures                — one zoom per recorded shake / circle / ⌃⌘Z mark.
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
            addTalkingHeadButton
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

    /// Second full-width action, violet like its timeline keyframe. Greys
    /// out — with the reason in its tooltip — when there's no webcam to swap
    /// in, too little timeline left, or the playhead is already inside a
    /// talking head. The same `insertionConflict` gates `apply`, so the
    /// button can never offer an insert the command would reject.
    private var addTalkingHeadButton: some View {
        let conflict = talkingHeadCommand.insertionConflict(in: project)
        let disabled = anyGenerating || conflict != nil
        let tint = Theme.Color.effectTalkingHead
        return Button {
            addTalkingHeadAtPlayhead()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "person.crop.rectangle.fill")
                    .font(.system(size: 13, weight: .semibold))
                Text("Add Talking Head at Playhead")
            }
            .font(Theme.Font.bodyEmphasized)
            .frame(maxWidth: .infinity)
            .frame(minHeight: 34)
            .foregroundStyle(disabled ? Theme.Color.textTertiary : tint)
            .background(disabled ? Theme.Color.bgElevated : tint.opacity(0.14))
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous)
                    .strokeBorder(disabled ? Theme.Color.borderSubtle : tint.opacity(0.32),
                                  lineWidth: Theme.Stroke.hairline)
            )
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .help(conflict.map { "Can't add a talking head: \($0)." }
              ?? "Show the webcam full-frame for a few seconds from the playhead. Drag its edges on the Effects row to set the length.")
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

    /// All sidecar-aggregation + generation logic lives in the shared
    /// `AutoZoomGenerator` (also used by ProjectView's on-open auto pass);
    /// this view just drives it and renders status.
    private var generator: AutoZoomGenerator {
        AutoZoomGenerator(project: project, bundleURL: bundleURL)
    }

    private var canGenerate: Bool { generator.canGenerate }
    private var disabledReason: String? { generator.disabledReason }

    private func generateAutoZoomFromPauses() async {
        guard canGenerate else { return }
        isGeneratingPauses = true
        lastError = nil
        lastSuccess = nil
        defer { isGeneratingPauses = false }

        let result = await generator.buildPausesCommand()
        guard let command = result.command else {
            lastError = result.error ?? "No cursor pauses long enough for auto-zoom."
            return
        }
        onApply(command)
        lastSuccess = "Generated \(result.count) zoom keyframe\(result.count == 1 ? "" : "s")."
        if let first = result.firstZoomTime {
            onSeek(.seconds(first))
        }
    }

    private func generateZoomsFromGestures() async {
        guard generator.canGenerate else { return }
        isGeneratingGestures = true
        lastError = nil
        lastSuccess = nil
        defer { isGeneratingGestures = false }

        let aggregated = await generator.aggregate { sidecar, naturalSize in
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
        if generator.canGenerate {
            let aggregated = await generator.aggregate { sidecar, naturalSize -> ([AutoZoomClick], [MouseTrajectorySample]) in
                ([], AutoZoomService.mouseTrajectory(from: sidecar, screenPixelSize: naturalSize))
            }
            if let sample = nearestTrajectorySample(in: aggregated.trajectory, at: playheadTime) {
                anchorX = sample.centerX
                anchorY = sample.centerY
                didAnchorToCursor = true
            }
        }

        let timelineDuration = generator.projectDuration
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

    // MARK: - Talking head

    private var talkingHeadCommand: AddTalkingHeadAtPlayheadCommand {
        AddTalkingHeadAtPlayheadCommand(
            timelineTime: playheadTime,
            timelineDuration: generator.projectDuration
        )
    }

    /// Synchronous — no sidecar work; the keyframe has no anchor to seed.
    private func addTalkingHeadAtPlayhead() {
        lastError = nil
        lastSuccess = nil
        let command = talkingHeadCommand
        if let reason = command.insertionConflict(in: project) {
            lastError = reason
            return
        }
        onApply(command)
        lastSuccess = "Added talking head at playhead — drag its edges on the Effects row to set the length."
        onSeek(.seconds(max(0, playheadTime)))
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
}
