import CoreGraphics
import Foundation
import PixelbayCore
import PixelbayInputCapture

// Edit-time glue between the clicks sidecar written by PixelbayInputCapture
// during capture and the auto-zoom keyframe generation in
// `GenerateAutoZoomFromClicksCommand`. All members are pure (no I/O): the app
// target reads the sidecar from disk via `ClicksSidecarStore.read(from:)` and
// loads the screen recording's natural pixel size via AVAsset, then feeds the
// results here.
//
// Two-step conversion the caller is expected to perform:
//   1. Locate the screen `MediaAsset` (kind == .display) in the project.
//   2. Resolve the sidecar URL via `clicksSidecarURL(forScreenAsset:in:)`,
//      read it via `ClicksSidecarStore.read(from:)`, and pass to
//      `autoZoomClicks(from:screenPixelSize:)`. Then dispatch
//      `GenerateAutoZoomFromClicksCommand(clicks:)`.
//
// Click x/y are normalised against the screen recording's natural pixel size.
// Multi-display setups + DPI scaling are a known limitation — clicks from a
// non-recorded display will fall outside (0..1) and get clamped (or default
// to 0.5/0.5 if the screen size is degenerate).
public enum AutoZoomService {

    // MARK: - Filename helpers

    /// Pull the session ID out of a screen MediaAsset's `relativePath`.
    ///
    /// The capture pipeline names screen files as `media/screen-<sessionID>.mov`
    /// (see `CaptureOutputDeriver.outputs(...)` in PixelbayCapture). The clicks
    /// sidecar uses the same id (`media/clicks-<sessionID>.json`).
    ///
    /// Returns nil if the path's basename doesn't start with `screen-` or has
    /// no extension separator.
    public static func sessionID(fromScreenRelativePath path: String) -> String? {
        let basename = (path as NSString).lastPathComponent
        guard basename.hasPrefix("screen-") else { return nil }
        let afterPrefix = basename.dropFirst("screen-".count)
        guard let dotIdx = afterPrefix.firstIndex(of: ".") else { return nil }
        let id = String(afterPrefix[..<dotIdx])
        return id.isEmpty ? nil : id
    }

    /// Compute the clicks sidecar URL for a screen MediaAsset inside a project bundle.
    /// Returns nil for non-display assets or unparseable filenames.
    public static func clicksSidecarURL(
        forScreenAsset asset: MediaAsset,
        in bundleURL: URL
    ) -> URL? {
        guard asset.kind == .display else { return nil }
        guard let id = sessionID(fromScreenRelativePath: asset.relativePath) else { return nil }
        return bundleURL
            .appendingPathComponent("media", isDirectory: true)
            .appendingPathComponent(ClicksSidecarStore.filename(for: id))
    }

    // MARK: - Project lookup

    /// Find the first MediaAsset whose `kind == .display`. Phase 1 / 2 records
    /// at most one screen per project so this is sufficient; mid-recording
    /// window swap (Phase 4) will need to be generalised.
    public static func screenAsset(in project: Project) -> MediaAsset? {
        project.assets.first(where: { $0.kind == .display })
    }

    // MARK: - Click conversion

    /// Convert a `ClicksSidecar` to a list of `AutoZoomClick`s in the project's
    /// timeline-time domain with normalised (0..1) screen coordinates.
    ///
    /// - Drops events with `timestamp < sidecar.captureStart` (clicks before
    ///   capture started — those shouldn't exist in practice but defend
    ///   against clock skew).
    /// - When `leftButtonOnly` is true (the default), filters out right
    ///   clicks: those are usually context-menu opens, not the "look at this"
    ///   signal auto-zoom is built around.
    /// - When `screenPixelSize` has zero or negative dimensions, falls back to
    ///   centre (0.5, 0.5) per `AutoZoomClick`'s init default rather than
    ///   producing NaN.
    /// - Otherwise normalises and clamps to `[0, 1]`.
    ///
    /// `sidecar.version >= 3` already carries normalised coordinates (the
    /// writer divided by the recorded display's points size) — this method
    /// passes them through with a clamp, ignoring `screenPixelSize`. v1/v2
    /// sidecars are raw global points and still get divided by
    /// `screenPixelSize` (the legacy path — wrong on Retina because the
    /// recording's pixel size doesn't match the screen's points size, but
    /// kept so pre-2026-05-13 sidecars still produce zooms at all).
    public static func autoZoomClicks(
        from sidecar: ClicksSidecar,
        screenPixelSize: CGSize,
        leftButtonOnly: Bool = true
    ) -> [AutoZoomClick] {
        let isPreNormalised = sidecar.version >= 3
        let hasValidSize = screenPixelSize.width > 0 && screenPixelSize.height > 0
        return sidecar.events.compactMap { event -> AutoZoomClick? in
            if leftButtonOnly && event.button != .left { return nil }
            let timelineTime = event.timestamp - sidecar.captureStart
            if timelineTime < 0 { return nil }
            if isPreNormalised {
                return AutoZoomClick(
                    timelineTime: timelineTime,
                    centerX: clamp01(event.x),
                    centerY: clamp01(event.y)
                )
            }
            if hasValidSize {
                let nx = clamp01(event.x / Double(screenPixelSize.width))
                let ny = clamp01(event.y / Double(screenPixelSize.height))
                return AutoZoomClick(timelineTime: timelineTime, centerX: nx, centerY: ny)
            } else {
                return AutoZoomClick(timelineTime: timelineTime)
            }
        }
    }

    /// Timeline-time instants of every recorded click (any button).
    /// Feeds `MouseTrajectory.clickPinnedSmoothed` so the stylized cursor
    /// path stays pixel-exact at interaction moments — right clicks count
    /// too (a context-menu open is just as position-critical as a left
    /// click). Mirrors the time-domain mapping in `autoZoomClicks`.
    public static func clickTimes(from sidecar: ClicksSidecar) -> [Double] {
        sidecar.events.compactMap { event in
            let timelineTime = event.timestamp - sidecar.captureStart
            return timelineTime >= 0 ? timelineTime : nil
        }
    }

    // MARK: - Mouse trajectory conversion (Phase 3b #7 slice 2/3)

    /// Convert a `ClicksSidecar`'s `moves` array to a list of
    /// `MouseTrajectorySample`s in the project's timeline-time domain. Mirrors
    /// `autoZoomClicks(...)`:
    /// - Drops samples with `timestamp < sidecar.captureStart`.
    /// - Normalises x/y to (0..1) against `screenPixelSize`; falls back to
    ///   centre (0.5, 0.5) when size is degenerate.
    /// - Output is in input order (the sidecar already writes moves in
    ///   chronological order via the decimating logger).
    public static func mouseTrajectory(
        from sidecar: ClicksSidecar,
        screenPixelSize: CGSize
    ) -> [MouseTrajectorySample] {
        let isPreNormalised = sidecar.version >= 3
        let hasValidSize = screenPixelSize.width > 0 && screenPixelSize.height > 0
        return sidecar.moves.compactMap { move -> MouseTrajectorySample? in
            let timelineTime = move.timestamp - sidecar.captureStart
            if timelineTime < 0 { return nil }
            if isPreNormalised {
                return MouseTrajectorySample(
                    timelineTime: timelineTime,
                    centerX: clamp01(move.x),
                    centerY: clamp01(move.y)
                )
            }
            if hasValidSize {
                let nx = clamp01(move.x / Double(screenPixelSize.width))
                let ny = clamp01(move.y / Double(screenPixelSize.height))
                return MouseTrajectorySample(timelineTime: timelineTime, centerX: nx, centerY: ny)
            } else {
                return MouseTrajectorySample(timelineTime: timelineTime, centerX: 0.5, centerY: 0.5)
            }
        }
    }

    /// Slice `master` to the samples whose `timelineTime` falls inside
    /// `timelineRange`. Thin forwarder onto `PixelbayCore.MouseTrajectory.window`
    /// — the type + helper migrated to Core so `PixelbayPlayback` can re-slice
    /// at composition build time without a circular dependency on Editor.
    public static func trajectoryWindow(
        _ master: [MouseTrajectorySample],
        timelineRange: TimeRange
    ) -> [ZoomTrajectorySample] {
        MouseTrajectory.window(master, timelineRange: timelineRange)
    }

    // MARK: - Manual zoom marks (slice #11.d)

    /// Convert a `ClicksSidecar`'s `marks` array to `AutoZoomClick`s in
    /// timeline-time. v4+ sidecars carry marks; older versions return [] since
    /// they have no marks array. Coordinate space mirrors `autoZoomClicks(...)`:
    /// v3+ values are already normalised, v1/v2 are dropped (no marks existed
    /// then anyway).
    public static func zoomMarks(
        from sidecar: ClicksSidecar,
        screenPixelSize: CGSize
    ) -> [AutoZoomClick] {
        let hasValidSize = screenPixelSize.width > 0 && screenPixelSize.height > 0
        return sidecar.marks.compactMap { mark -> AutoZoomClick? in
            let timelineTime = mark.timestamp - sidecar.captureStart
            if timelineTime < 0 { return nil }
            if sidecar.version >= 3 {
                return AutoZoomClick(
                    timelineTime: timelineTime,
                    centerX: clamp01(mark.x),
                    centerY: clamp01(mark.y),
                    source: mark.source
                )
            }
            if hasValidSize {
                return AutoZoomClick(
                    timelineTime: timelineTime,
                    centerX: clamp01(mark.x / Double(screenPixelSize.width)),
                    centerY: clamp01(mark.y / Double(screenPixelSize.height)),
                    source: mark.source
                )
            }
            return AutoZoomClick(timelineTime: timelineTime, source: mark.source)
        }
    }

    // Note: the legacy `filterClicks` dwell gate and `decelerationZooms`
    // synthetic-click generator were removed in the Phase 3c intent-scoring
    // rewrite. Both are replaced by `IntentScorer.score` /
    // `IntentScorer.selectFiring` in `IntentScorer.swift`.
}

private func clamp01(_ x: Double) -> Double {
    if x.isNaN { return 0.5 }
    return min(max(x, 0), 1)
}
