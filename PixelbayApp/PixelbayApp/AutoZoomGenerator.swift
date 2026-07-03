import AVFoundation
import CoreGraphics
import Foundation
import PixelbayCore
import PixelbayEditor
import PixelbayInputCapture

// Shared auto-zoom generation glue. Finds a project's screen recordings and
// their on-disk clicks sidecars, loads cursor telemetry, shifts it onto the
// project timeline (honouring each clip's trim / speed), and builds zoom-
// generation commands.
//
// Single source of truth for two callers:
//   • `ZoomActionsBar` — the manual "From Pauses" / "From Gestures" / "Add
//     Zoom" buttons in the inspector.
//   • `ProjectView`'s on-open auto pass — replicates OpenScreen's on-load
//     auto-suggest behaviour (`buildPausesCommand`).
//
// A pure value type (no view state): both callers construct one per use from
// the current project + bundle URL. All I/O (sidecar reads, AVAsset natural-
// size loads) is async and best-effort — a missing/failed sidecar drops that
// recording from the aggregate rather than failing the whole pass.
struct AutoZoomGenerator {
    let project: Project
    let bundleURL: URL

    /// A `.display` MediaAsset paired with the screen clip(s) that reference
    /// it AND its on-disk clicks sidecar.
    struct Pair {
        let asset: MediaAsset
        let clips: [Clip]
        let sidecarURL: URL
    }

    /// Aggregated per-project telemetry: gesture/click points and the full
    /// cursor trajectory, both already shifted onto the project timeline.
    struct Aggregated {
        let points: [AutoZoomClick]
        let trajectory: [MouseTrajectorySample]
        let firstError: String?
    }

    /// Result of the high-level dwell ("from pauses") build.
    struct PausesResult {
        /// nil when there are no pairs or no dwell suggestions.
        let command: GenerateAutoZoomFromClicksCommand?
        let count: Int
        /// Timeline time of the first generated zoom, for seek-to-first.
        let firstZoomTime: Double?
        /// User-facing reason nothing was generated (nil on success).
        let error: String?
    }

    // MARK: - Pair discovery

    /// Every screen recording in this project that has BOTH a referencing
    /// clip AND a sidecar file on disk.
    var availablePairs: [Pair] {
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
        var pairs: [Pair] = []
        for (id, clips) in clipsByAsset {
            guard let asset = screenAssetsByID[id] else { continue }
            guard let url = AutoZoomService.clicksSidecarURL(
                forScreenAsset: asset,
                in: bundleURL
            ) else { continue }
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            pairs.append(Pair(asset: asset, clips: clips, sidecarURL: url))
        }
        return pairs
    }

    var canGenerate: Bool { !availablePairs.isEmpty }

    /// Human-readable reason the generators can't run, or nil when they can.
    var disabledReason: String? {
        let hasScreenAsset = project.assets.contains(where: { $0.kind == .display })
        if !hasScreenAsset { return "No screen recording in this project." }
        let hasScreenClip = project.tracks
            .filter { $0.kind == .screen }
            .contains(where: { !$0.clips.isEmpty })
        if !hasScreenClip { return "Screen recording is not on the timeline." }
        if availablePairs.isEmpty {
            return "No clicks sidecar found — record with click logging enabled."
        }
        return nil
    }

    /// Total length of the project's timeline — `max(clip.timelineRange.end)`.
    var projectDuration: Double? {
        let ends = project.tracks.flatMap(\.clips).map { $0.timelineRange.end.seconds }
        return ends.max()
    }

    // MARK: - High-level: dwell / "from pauses"

    /// Build the dwell-based auto-zoom command from cursor pauses. Mirrors the
    /// OpenScreen `buildAutoZoomSuggestions` pass, routed around any manual
    /// zooms the user has placed. Returns `.command == nil` (with `.error`
    /// set) when there's no telemetry or no pause long enough to zoom.
    func buildPausesCommand() async -> PausesResult {
        guard canGenerate else {
            return PausesResult(command: nil, count: 0, firstZoomTime: nil, error: disabledReason)
        }
        let aggregated = await aggregate { sidecar, naturalSize in
            ([], AutoZoomService.mouseTrajectory(from: sidecar, screenPixelSize: naturalSize))
        }
        if aggregated.trajectory.isEmpty {
            return PausesResult(
                command: nil, count: 0, firstZoomTime: nil,
                error: aggregated.firstError
                    ?? "No cursor telemetry across this project's screen recordings."
            )
        }

        let manualZoomRanges = project.effects
            .filter { $0.kind == .zoom && $0.origin == .manualHotkey }
            .map(\.timelineRange)
        let duration = projectDuration ?? aggregated.trajectory.last?.timelineTime ?? 0
        let defaultDuration = EffectKeyframe.defaultZoomEaseIn.seconds
            + 1.8
            + EffectKeyframe.defaultZoomEaseOut.seconds
        let telemetry = aggregated.trajectory.map {
            CursorTelemetryPoint(timeMs: $0.timelineTime * 1000.0, cx: $0.centerX, cy: $0.centerY)
        }
        let autoClicks = AutoZoomService.dwellAutoZoomClicks(
            cursorTelemetry: telemetry,
            totalDuration: duration,
            existingRegions: manualZoomRanges,
            defaultDuration: defaultDuration
        )
        if autoClicks.isEmpty {
            return PausesResult(
                command: nil, count: 0, firstZoomTime: nil,
                error: "No cursor pauses long enough for auto-zoom."
            )
        }
        let command = GenerateAutoZoomFromClicksCommand(
            clicks: autoClicks,
            timelineDuration: duration,
            mouseTrajectory: aggregated.trajectory.isEmpty ? nil : aggregated.trajectory
        )
        return PausesResult(
            command: command,
            count: autoClicks.count,
            firstZoomTime: autoClicks.first?.timelineTime,
            error: nil
        )
    }

    // MARK: - Aggregation across screen recordings

    /// Walk every `Pair`, run `extract` on each loaded sidecar, shift the
    /// per-asset results onto the project timeline using each referencing
    /// clip's source/timeline ranges, then aggregate. The trajectory is
    /// returned sorted so downstream bracket scans pick the right neighbours
    /// across scene boundaries.
    func aggregate(
        _ extract: (ClicksSidecar, CGSize) -> ([AutoZoomClick], [MouseTrajectorySample])
    ) async -> Aggregated {
        var points: [AutoZoomClick] = []
        var trajectory: [MouseTrajectorySample] = []
        var firstError: String?
        for pair in availablePairs {
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
        return Aggregated(points: points, trajectory: trajectory, firstError: firstError)
    }

    // MARK: - Timeline mapping

    private func shiftClicks(_ clicks: [AutoZoomClick], into clip: Clip) -> [AutoZoomClick] {
        clicks.compactMap { click in
            guard let t = timelineTime(forSourceTime: click.timelineTime, in: clip) else { return nil }
            return AutoZoomClick(timelineTime: t, centerX: click.centerX, centerY: click.centerY, source: click.source)
        }
    }

    private func shiftTrajectory(_ samples: [MouseTrajectorySample], into clip: Clip) -> [MouseTrajectorySample] {
        samples.compactMap { sample in
            guard let t = timelineTime(forSourceTime: sample.timelineTime, in: clip) else { return nil }
            return MouseTrajectorySample(timelineTime: t, centerX: sample.centerX, centerY: sample.centerY)
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
                domain: "AutoZoomGenerator",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Screen recording has no video track."]
            )
        }
        let naturalSize = try await firstTrack.load(.naturalSize)
        return (sidecar, naturalSize)
    }
}
