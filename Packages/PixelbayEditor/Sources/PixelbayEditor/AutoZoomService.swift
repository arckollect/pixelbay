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
                    centerY: clamp01(mark.y)
                )
            }
            if hasValidSize {
                return AutoZoomClick(
                    timelineTime: timelineTime,
                    centerX: clamp01(mark.x / Double(screenPixelSize.width)),
                    centerY: clamp01(mark.y / Double(screenPixelSize.height))
                )
            }
            return AutoZoomClick(timelineTime: timelineTime)
        }
    }

    // MARK: - Smart-filter pre-pass (slice #11.d)

    /// Drop clicks where the cursor was moving faster than `maxVelocity`
    /// (normalised-units per second, screen-fraction/s) in the
    /// `dwellWindow`-second window immediately before each click. The cursor
    /// being "still" is a proxy for "the user was paying attention here";
    /// clicks made while ripping the cursor across menus are filtered out.
    ///
    /// When `masterTrajectory` is nil or has fewer than 2 samples, the filter
    /// degrades gracefully and returns the input unchanged — the auto-zoom
    /// path still works on click-only sidecars.
    public static func filterClicks(
        _ clicks: [AutoZoomClick],
        masterTrajectory: [MouseTrajectorySample]?,
        dwellWindow: Double = 0.25,
        // 0.50 norm-units/s = half the screen width per second. Ordinary
        // "moving toward a button I want to click" motion is 0.2-0.8; only
        // "ripping the cursor through menus" exceeds 0.50 sustained. The
        // original 0.10 threshold dropped most real clicks because typical
        // pointing motion exceeds 10% screen-width/s in the approach phase.
        maxVelocity: Double = 0.50
    ) -> [AutoZoomClick] {
        guard let trajectory = masterTrajectory, trajectory.count >= 2 else {
            return clicks
        }
        return clicks.filter { click in
            let windowStart = click.timelineTime - dwellWindow
            // Find samples inside [windowStart, click.timelineTime]. Trajectory
            // is sorted by timelineTime (it's the master sequence).
            var totalDistance = 0.0
            var prior: MouseTrajectorySample?
            for sample in trajectory {
                if sample.timelineTime < windowStart { prior = sample; continue }
                if sample.timelineTime > click.timelineTime { break }
                if let p = prior {
                    let dx = sample.centerX - p.centerX
                    let dy = sample.centerY - p.centerY
                    totalDistance += (dx * dx + dy * dy).squareRoot()
                }
                prior = sample
            }
            let avgVelocity = totalDistance / dwellWindow
            return avgVelocity <= maxVelocity
        }
    }

    // MARK: - Deceleration trigger (slice #11.d)

    /// Synthesise an `AutoZoomClick` at each point in the master trajectory
    /// where the cursor velocity drops from "fast" to "slow" — i.e. the user
    /// was zipping around the screen and then settled near something. Catches
    /// click-light workflows (watching an animation, demoing a UI element via
    /// hover). Returns [] when the trajectory is empty or has < 3 samples.
    ///
    /// Tunables:
    ///  - `startVelocity` / `endVelocity` — the fast→slow transition envelope
    ///    in normalised-units/s. Defaults tuned for a 30 Hz capture rate.
    ///  - `lookbackWindow` — how far back to check for the "fast" condition
    ///    after the cursor slows. Keeps us from firing on momentary pauses.
    ///  - `coalesceWindow` — minimum spacing between emitted decel triggers.
    public static func decelerationZooms(
        from masterTrajectory: [MouseTrajectorySample]?,
        startVelocity: Double = 0.40,
        endVelocity: Double = 0.05,
        lookbackWindow: Double = 0.50,
        coalesceWindow: Double = 2.0
    ) -> [AutoZoomClick] {
        guard let trajectory = masterTrajectory, trajectory.count >= 3 else { return [] }

        // Per-sample instantaneous velocity (norm-units/s). Sample 0 has no
        // prior, so its velocity is undefined — we record 0 there.
        var velocities: [Double] = [0]
        velocities.reserveCapacity(trajectory.count)
        for i in 1..<trajectory.count {
            let p = trajectory[i - 1]
            let s = trajectory[i]
            let dt = s.timelineTime - p.timelineTime
            guard dt > 0 else { velocities.append(velocities[i - 1]); continue }
            let dx = s.centerX - p.centerX
            let dy = s.centerY - p.centerY
            velocities.append((dx * dx + dy * dy).squareRoot() / dt)
        }

        // Box-smooth velocity (radius 2 → ~5 samples / ~165ms at 30 Hz) so
        // single-sample noise doesn't fire spurious transitions.
        let smoothedVelocities: [Double] = (0..<velocities.count).map { i in
            let lo = max(0, i - 2)
            let hi = min(velocities.count - 1, i + 2)
            let slice = velocities[lo...hi]
            return slice.reduce(0, +) / Double(slice.count)
        }

        var results: [AutoZoomClick] = []
        var lastEmittedAt: Double = -.infinity
        for i in 1..<smoothedVelocities.count {
            let v = smoothedVelocities[i]
            let prev = smoothedVelocities[i - 1]
            // Transition: previous sample was above (or AT) endVelocity, this
            // one drops below it — "the cursor just settled". Require a
            // fast-sample within `lookbackWindow` to qualify the deceleration.
            guard prev > endVelocity, v <= endVelocity else { continue }
            let sample = trajectory[i]
            if sample.timelineTime - lastEmittedAt < coalesceWindow { continue }
            // Look back for a fast sample in the prior `lookbackWindow`.
            var sawFast = false
            for j in stride(from: i - 1, through: 0, by: -1) {
                if sample.timelineTime - trajectory[j].timelineTime > lookbackWindow { break }
                if smoothedVelocities[j] >= startVelocity { sawFast = true; break }
            }
            guard sawFast else { continue }
            results.append(AutoZoomClick(
                timelineTime: sample.timelineTime,
                centerX: clamp01(sample.centerX),
                centerY: clamp01(sample.centerY)
            ))
            lastEmittedAt = sample.timelineTime
        }
        return results
    }
}

private func clamp01(_ x: Double) -> Double {
    if x.isNaN { return 0.5 }
    return min(max(x, 0), 1)
}
