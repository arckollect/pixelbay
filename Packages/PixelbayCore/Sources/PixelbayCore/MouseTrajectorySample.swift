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

    /// Camera-follow damping with **velocity-adaptive** time constant.
    /// Smooths the master cursor trajectory through a critically-damped
    /// spring whose `τ` scales with the cursor's instantaneous speed:
    /// near-stationary input collapses τ toward `tauLow` so the spring
    /// tracks tightly (no perceptible lag on precise clicks), while a
    /// fast sweep ramps τ toward `tauHigh` so the on-screen motion reads
    /// as a long glide rather than a strobe-fast streak. Output drives
    /// BOTH the cursor sprite and the zoom anchor (Screen Studio /
    /// Loom pattern) — sharing one filter keeps sprite + camera locked
    /// together; the velocity adaptivity is what avoids the "delayed
    /// cursor on click" failure mode the old fixed-τ shared design hit.
    ///
    /// Speed is measured as the magnitude of the inter-sample displacement
    /// per second (norm-units / s), then low-passed by a one-pole EMA
    /// (`velocityEmaTau`) so τ doesn't whiplash on micro-jitter. The blend
    /// from `tauLow` → `tauHigh` is a smoothstep over `[vLow, vHigh]`.
    ///
    /// Defaults (norm-units = fraction of screen width):
    ///   • `tauLow = 0.05` → 5τ settle = 0.25 s when stationary (snappy click feel)
    ///   • `tauHigh = 0.32` → big glide on cross-screen sweeps
    ///   • `vLow = 0.15`, `vHigh = 1.20` → adaptivity kicks in once the
    ///     cursor crosses casual-motion speed, fully engaged on screen-sweep
    ///   • `velocityEmaTau = 0.05` → speed estimate catches up to a stop
    ///     within ~0.1 s, so τ drops fast when the user halts to click
    ///
    /// Steady-state lag at constant `v` is `2·v·τ(v)`; at the precise-click
    /// regime (v ≈ 0.2 norm/s, τ ≈ 0.05) that's ~0.02 norm-units — beneath
    /// perception. During a fast sweep the spring never reaches steady
    /// state (sweep is shorter than ~5τ ≈ 1.6 s), so the trailing distance
    /// is bounded by the sweep length and reads as a glide that decelerates
    /// into the destination.
    public static func cameraDamped(
        _ master: [MouseTrajectorySample],
        tauLow: Double = 0.05,
        tauHigh: Double = 0.32,
        vLow: Double = 0.15,
        vHigh: Double = 1.20,
        velocityEmaTau: Double = 0.05
    ) -> [MouseTrajectorySample] {
        guard master.count > 1 else { return master }
        let safeTauLow = max(0.01, tauLow)
        let safeTauHigh = max(safeTauLow, tauHigh)
        let safeVelEma = max(0.005, velocityEmaTau)
        var result: [MouseTrajectorySample] = []
        result.reserveCapacity(master.count)
        var x: Double = master[0].centerX
        var y: Double = master[0].centerY
        var vx: Double = 0.0
        var vy: Double = 0.0
        var prevT: Double = master[0].timelineTime
        var smoothedSpeed: Double = 0.0
        result.append(master[0])
        for i in 1..<master.count {
            let sample = master[i]
            let dtTotal: Double = max(0.0, sample.timelineTime - prevT)
            if dtTotal <= 0 {
                result.append(MouseTrajectorySample(
                    timelineTime: sample.timelineTime,
                    centerX: x,
                    centerY: y
                ))
                continue
            }
            let dx = sample.centerX - master[i - 1].centerX
            let dy = sample.centerY - master[i - 1].centerY
            let inputSpeed = (dx * dx + dy * dy).squareRoot() / dtTotal
            // First-order low-pass on speed: dt-aware alpha so the EMA
            // behaves consistently across capture rates.
            let alpha = 1.0 - exp(-dtTotal / safeVelEma)
            smoothedSpeed += alpha * (inputSpeed - smoothedSpeed)
            let blend = MouseTrajectory.smoothstep(vLow, vHigh, smoothedSpeed)
            let tau = safeTauLow + (safeTauHigh - safeTauLow) * blend
            let omega = 1.0 / tau
            let stiffness = omega * omega
            let dampingCoef = 2.0 * omega
            let maxStep = tau * 0.25
            var remaining = dtTotal
            while remaining > 0 {
                let step = min(maxStep, remaining)
                let ax = stiffness * (sample.centerX - x) - dampingCoef * vx
                let ay = stiffness * (sample.centerY - y) - dampingCoef * vy
                vx += ax * step
                vy += ay * step
                x += vx * step
                y += vy * step
                remaining -= step
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

    @inline(__always)
    private static func smoothstep(_ edge0: Double, _ edge1: Double, _ x: Double) -> Double {
        guard edge1 > edge0 else { return x < edge0 ? 0 : 1 }
        let t = min(1.0, max(0.0, (x - edge0) / (edge1 - edge0)))
        return t * t * (3.0 - 2.0 * t)
    }

    /// Lazy-follow deadzone for cursor-follow zoom anchors. The Screen Studio
    /// pattern: the visible zoom frame holds still while the cursor roams
    /// inside a generous central region, and only pans once the cursor
    /// approaches the padding edge.
    ///
    /// Implementation: walk the smoothed cursor samples in order, maintain
    /// a single 2D anchor seeded at `samples[0]`. For each subsequent
    /// sample, if the cursor strays past the deadzone half-width on either
    /// axis, drag the anchor along by exactly the excess (hard rectangular
    /// pull-toward-edge). The result is a piecewise-flat-then-ramp
    /// trajectory that Catmull-Rom interpolation downstream
    /// (`EffectEvaluator.zoomCenter`) smooths into clean pans.
    ///
    /// `deadzoneFraction` is the fraction of the *zoomed* viewport that the
    /// cursor can occupy before the frame starts following — 0.50 means the
    /// cursor can wander across the middle 50% of the visible frame
    /// without the camera moving. Maps to source-norm half-width as
    /// `(deadzoneFraction / 2) / max(1, zoomFactor)` per axis.
    ///
    /// Pinned (gesture) keyframes bypass this entirely upstream — they want
    /// the anchor locked, not lazy-following.
    public static func lazyFollow(
        _ samples: [ZoomTrajectorySample],
        zoomFactor: Double,
        deadzoneFraction: Double = 0.50
    ) -> [ZoomTrajectorySample] {
        guard let first = samples.first else { return [] }
        guard samples.count > 1 else { return samples }
        let safeZoom = max(1.0, zoomFactor)
        let halfX = (deadzoneFraction / 2.0) / safeZoom
        let halfY = halfX
        var anchorX = first.x
        var anchorY = first.y
        var result: [ZoomTrajectorySample] = []
        result.reserveCapacity(samples.count)
        result.append(first)
        for i in 1..<samples.count {
            let s = samples[i]
            let dx = s.x - anchorX
            if dx > halfX {
                anchorX += dx - halfX
            } else if dx < -halfX {
                anchorX += dx + halfX
            }
            let dy = s.y - anchorY
            if dy > halfY {
                anchorY += dy - halfY
            } else if dy < -halfY {
                anchorY += dy + halfY
            }
            result.append(ZoomTrajectorySample(t: s.t, x: anchorX, y: anchorY))
        }
        return result
    }
}
