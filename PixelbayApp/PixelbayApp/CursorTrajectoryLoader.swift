import AVFoundation
import Foundation
import OSLog
import PixelbayCore
import PixelbayEditor
import PixelbayInputCapture

private let log = Logger(subsystem: "com.pixelbay.PixelbayApp", category: "CursorTrajectoryLoader")

// App-target glue: load the cursor trajectory from a project's clicks
// sidecar so PreviewCompositionBuilder.build / PreviewPlayer.load can
// re-slice each zoom keyframe's trajectory against its CURRENT timeline
// range at composition build time. Without re-slicing, dragging a zoom
// keyframe's right edge to extend the hold window doesn't extend cursor-
// follow — the slice stored on the keyframe only covers samples in the
// originally-generated range, and the evaluator clamps to the last
// stored sample.
//
// Phase 5 multi-scene support: after a scenes merge, the project carries
// N screen assets (one per merged scene) each with its own clicks-*.json
// sidecar. The loader walks every screen-kind track's clips, pairs each
// clip with its underlying asset's sidecar, maps each per-asset sample's
// progress through `clip.sourceRange` into the clip's actual timeline span
// (including speed changes), then concatenates into a single master
// trajectory. The compositor consumes the merged stream unchanged; per-frame
// trajectory sampling already does a linear scan by timelineTime, so
// back-to-back scene clips render cursor-follow as one continuous path.
//
// Three call sites use this (ProjectView's .task, PostCaptureView's load
// path, ExportSheet.runExport) so it lives here rather than being
// inlined three times.

enum CursorTrajectoryLoader {

    /// The master cursor trajectory plus the timeline-time instants of
    /// every recorded click. The trajectory is the raw post-production input
    /// for cursor-follow zooms; click times are retained for compatibility
    /// with older smoothing/export call sites.
    struct CursorData {
        var samples: [MouseTrajectorySample]
        var clickTimes: [Double]
    }

    /// Returns the master cursor trajectory + click times for `project`,
    /// or nil when there's no screen asset, no sidecar, or the sidecars
    /// carry no mouse-move samples. Silent on errors: any I/O failure for
    /// a single asset is dropped so the preview still loads — cursor-follow
    /// simply falls back to the per-keyframe stored slice (or, when that's
    /// nil/empty, the static centre).
    ///
    /// In a single-asset project (the only Phase 1–4 shape) the returned
    /// trajectory is identical to what the pre-Phase-5 loader produced.
    static func load(
        for project: Project,
        bundleURL: URL
    ) async -> CursorData? {
        let pairs = screenClipsByAsset(in: project)
        guard !pairs.isEmpty else { return nil }

        var merged: [MouseTrajectorySample] = []
        var mergedClicks: [Double] = []
        for (asset, clips) in pairs {
            guard let sidecarURL = AutoZoomService.clicksSidecarURL(
                forScreenAsset: asset,
                in: bundleURL
            ) else { continue }
            guard FileManager.default.fileExists(atPath: sidecarURL.path) else { continue }

            do {
                let sidecar = try ClicksSidecarStore.read(from: sidecarURL)
                guard !sidecar.moves.isEmpty else { continue }
                let naturalSize = try await naturalPixelSize(
                    for: try ProjectBundle(url: bundleURL).mediaURL(for: asset)
                )
                let perAsset = AutoZoomService.mouseTrajectory(
                    from: sidecar,
                    screenPixelSize: naturalSize
                )
                guard !perAsset.isEmpty else { continue }
                let perAssetClicks = AutoZoomService.clickTimes(from: sidecar)
                for clip in clips {
                    merged.append(contentsOf: shift(
                        perAsset,
                        intoClipTimeline: clip
                    ))
                    mergedClicks.append(contentsOf: shiftTimes(
                        perAssetClicks,
                        intoClipTimeline: clip
                    ))
                }
            } catch {
                log.error("trajectory load failed for asset \(asset.relativePath, privacy: .public): \(String(describing: error), privacy: .public)")
                continue
            }
        }

        // Defensive sort: scenes can be merged/reordered and each screen clip
        // contributes its own shifted sidecar slice. The compositor's
        // linear-bracket-pair scan expects a timeline-ordered master stream.
        let sorted = merged.sorted { $0.timelineTime < $1.timelineTime }
        return sorted.isEmpty
            ? nil
            : CursorData(samples: sorted, clickTimes: mergedClicks.sorted())
    }

    // MARK: - Helpers

    private static func screenClipsByAsset(
        in project: Project
    ) -> [(asset: MediaAsset, clips: [Clip])] {
        let screenAssetByID: [MediaAssetID: MediaAsset] = Dictionary(
            project.assets
                .filter { $0.kind == .display }
                .map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var grouped: [MediaAssetID: [Clip]] = [:]
        for track in project.tracks where track.kind == .screen {
            for clip in track.clips where screenAssetByID[clip.assetID] != nil {
                grouped[clip.assetID, default: []].append(clip)
            }
        }
        return grouped.compactMap { (id, clips) -> (MediaAsset, [Clip])? in
            guard let asset = screenAssetByID[id] else { return nil }
            return (asset, clips)
        }
    }

    private static func naturalPixelSize(for url: URL) async throws -> CGSize {
        let avAsset = AVURLAsset(url: url)
        let videoTracks = try await avAsset.loadTracks(withMediaType: .video)
        guard let track = videoTracks.first else { return .zero }
        return try await track.load(.naturalSize)
    }

    /// Per-asset samples have `timelineTime` in the recording's own time
    /// domain (t=0 at the asset's `captureStart`). To project them onto the
    /// editor's timeline we map progress through the clip's `sourceRange`
    /// (which part of the asset the clip uses) into `timelineRange` (where
    /// and how long the clip sits in the timeline). Samples outside the clip's
    /// source range are dropped — they correspond to material the editor
    /// trimmed off.
    private static func shift(
        _ samples: [MouseTrajectorySample],
        intoClipTimeline clip: Clip
    ) -> [MouseTrajectorySample] {
        let sourceStart = clip.sourceRange.start.seconds
        let sourceEnd = clip.sourceRange.end.seconds
        let sourceDuration = clip.sourceRange.duration.seconds
        let timelineStart = clip.timelineRange.start.seconds
        let timelineDuration = clip.timelineRange.duration.seconds
        guard sourceDuration > 0, timelineDuration > 0 else { return [] }
        return samples.compactMap { sample -> MouseTrajectorySample? in
            guard sample.timelineTime >= sourceStart,
                  sample.timelineTime <= sourceEnd
            else { return nil }
            let sourceProgress = (sample.timelineTime - sourceStart) / sourceDuration
            return MouseTrajectorySample(
                timelineTime: timelineStart + sourceProgress * timelineDuration,
                centerX: sample.centerX,
                centerY: sample.centerY
            )
        }
    }

    /// Same source-range → timeline mapping as `shift`, for bare click
    /// instants.
    private static func shiftTimes(
        _ times: [Double],
        intoClipTimeline clip: Clip
    ) -> [Double] {
        let sourceStart = clip.sourceRange.start.seconds
        let sourceEnd = clip.sourceRange.end.seconds
        let sourceDuration = clip.sourceRange.duration.seconds
        let timelineStart = clip.timelineRange.start.seconds
        let timelineDuration = clip.timelineRange.duration.seconds
        guard sourceDuration > 0, timelineDuration > 0 else { return [] }
        return times.compactMap { time -> Double? in
            guard time >= sourceStart, time <= sourceEnd else { return nil }
            let sourceProgress = (time - sourceStart) / sourceDuration
            return timelineStart + sourceProgress * timelineDuration
        }
    }
}
