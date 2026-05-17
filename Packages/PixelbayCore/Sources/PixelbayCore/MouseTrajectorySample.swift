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

    /// Camera-follow damping. Smooths the master cursor trajectory through
    /// a critically-damped spring — no overshoot, decelerates naturally at
    /// the ends of a sweep, tracks slow precise motion closely. Fed once
    /// per composition build into BOTH the cursor sprite render and the
    /// zoom anchor (see `PreviewCompositionBuilder.build`), so sprite and
    /// camera move as one body — the cursor visibly glides, and the zoom
    /// stays glued to the cursor instead of trailing behind it. This is
    /// the Screen Studio / Loom pattern; the earlier split-path design
    /// (raw sprite + damped anchor) produced a cursor that raced toward
    /// the frame edge during fast sweeps, which the user reported as
    /// "too quick and hard for the eyes to follow."
    ///
    /// Time-domain (not sample-domain) so the feel is consistent across
    /// recording rates: at `tau = 0.18` the spring reaches 95 % of any
    /// step change in ~0.85 s regardless of whether samples arrive at
    /// 30 Hz or 120 Hz.
    ///
    /// `tau` is the spring's natural-frequency time constant
    /// (`ωn = 1/τ`). Now that the output drives BOTH sprite and anchor,
    /// τ controls a unified visual lag (cursor sprite vs real input),
    /// not a camera-vs-cursor lag. Steady-state sprite lag at a 0.2
    /// norm/sec "precise click" move is `2·v·τ` ≈ 0.072 norm-units
    /// (~7 % of frame width) — noticeable but not soggy; the spring
    /// catches up in ~5τ ≈ 0.9 s of pointer-stop, so clicks visually
    /// resolve quickly. History: 0.12 (original, anchor-only damping)
    /// read as "too quick"; 0.25 (anchor-only) read as buttery but let
    /// the cursor drift to the edge; 0.18 is the current shared-damping
    /// default. Sweet-spot range is roughly 0.15–0.22; below 0.12 the
    /// motion stops feeling cinematic, above 0.25 the sprite feels
    /// delayed on precise clicks.
    public static func cameraDamped(
        _ master: [MouseTrajectorySample],
        tau: Double = 0.18
    ) -> [MouseTrajectorySample] {
        guard master.count > 1 else { return master }
        let safeTau = max(0.05, tau)
        // Critically damped second-order: ω = 1/τ, damping = 1. Position
        // converges to target without overshoot in ~5τ. Semi-implicit
        // Euler with variable dt (input samples are unevenly spaced under
        // capture-side coalescing). Sub-stepping caps dt at τ/4 so large
        // gaps don't blow up the integrator on slow recordings.
        let omega: Double = 1.0 / safeTau
        let stiffness: Double = omega * omega
        let dampingCoef: Double = 2.0 * omega
        var result: [MouseTrajectorySample] = []
        result.reserveCapacity(master.count)
        var x: Double = master[0].centerX
        var y: Double = master[0].centerY
        var vx: Double = 0.0
        var vy: Double = 0.0
        var prevT: Double = master[0].timelineTime
        result.append(master[0])
        let maxStep: Double = safeTau * 0.25
        for i in 1..<master.count {
            let sample = master[i]
            var remaining: Double = max(0.0, sample.timelineTime - prevT)
            while remaining > 0 {
                let dt: Double = min(maxStep, remaining)
                let ax: Double = stiffness * (sample.centerX - x) - dampingCoef * vx
                let ay: Double = stiffness * (sample.centerY - y) - dampingCoef * vy
                vx += ax * dt
                vy += ay * dt
                x += vx * dt
                y += vy * dt
                remaining -= dt
            }
            prevT = sample.timelineTime
            result.append(MouseTrajectorySample(
                timelineTime: sample.timelineTime,
                centerX: x,
                centerY: y
            ))
        }
        return result
    }
}
