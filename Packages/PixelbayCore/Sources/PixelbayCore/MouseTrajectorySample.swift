import Foundation

/// One mouse-position sample in the project's timeline-time domain. Derived
/// from `ClicksSidecar.moves` at edit time and threaded through the preview
/// composition so the compositor can re-slice it against each zoom
/// keyframe's CURRENT timeline range — letting trim-edge drags extend
/// cursor-follow into samples that weren't part of the keyframe's original
/// auto-generated slice.
///
/// Lives in PixelbayCore (not PixelbayEditor where it was born) because
/// PixelbayPlayback also needs it now (re-slicing happens at composition
/// build time) and Playback can't depend on Editor.
public struct MouseTrajectorySample: Sendable, Equatable {
    public var timelineTime: Double
    public var centerX: Double
    public var centerY: Double

    public init(timelineTime: Double, centerX: Double, centerY: Double) {
        self.timelineTime = timelineTime
        self.centerX = centerX
        self.centerY = centerY
    }
}

public enum MouseTrajectory {

    /// Slice `master` to the samples whose `timelineTime` falls inside
    /// `timelineRange`, re-based to keyframe-local time (t=0 at
    /// `timelineRange.start`). Returns an empty array when `master` is
    /// empty, the range is degenerate, or no samples fall in
    /// `[start, end]`. The compositor evaluator clamps lookups outside
    /// `[t_first, t_last]` to the nearest sample — no synthetic boundary
    /// anchoring is inserted here.
    public static func window(
        _ master: [MouseTrajectorySample],
        timelineRange: TimeRange
    ) -> [ZoomTrajectorySample] {
        let start = timelineRange.start.seconds
        let duration = timelineRange.duration.seconds
        guard duration > 0 else { return [] }
        let end = start + duration
        return master.compactMap { sample -> ZoomTrajectorySample? in
            guard sample.timelineTime >= start, sample.timelineTime <= end else { return nil }
            return ZoomTrajectorySample(
                t: sample.timelineTime - start,
                x: sample.centerX,
                y: sample.centerY
            )
        }
    }

    /// Apply a one-pole IIR exponential moving average to a master
    /// trajectory. Smooths sub-sample-rate jitter — the 30Hz capture rate
    /// produces velocity discontinuities at each sample boundary under
    /// linear interpolation, which read as a robotic / jerky cursor
    /// follow. `alpha` is the weight of the new sample; lower values give
    /// more smoothing but also more lag. Defaults to 0.22 (longer lag
    /// than the original 0.35, but the 1.6× zoom amplifies sub-sample
    /// velocity discontinuities enough that more aggressive low-pass
    /// reads as "smooth follow" rather than "soggy follow").
    ///
    /// Returns a same-length array with the same `timelineTime` values
    /// preserved; only `centerX` / `centerY` are filtered.
    public static func smoothed(
        _ master: [MouseTrajectorySample],
        alpha: Double = 0.22
    ) -> [MouseTrajectorySample] {
        guard master.count > 1 else { return master }
        let a = max(0.001, min(1.0, alpha))
        var result: [MouseTrajectorySample] = []
        result.reserveCapacity(master.count)
        var sx = master[0].centerX
        var sy = master[0].centerY
        result.append(master[0])
        for i in 1..<master.count {
            let raw = master[i]
            sx = a * raw.centerX + (1 - a) * sx
            sy = a * raw.centerY + (1 - a) * sy
            result.append(MouseTrajectorySample(
                timelineTime: raw.timelineTime,
                centerX: sx,
                centerY: sy
            ))
        }
        return result
    }
}
