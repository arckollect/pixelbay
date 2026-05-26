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
    ///
    /// `leadSeconds` shifts the slice's *start* forward in time by that
    /// amount, while keeping the re-based origin at `timelineRange.start`.
    /// So with `leadSeconds = 0.15`, the first sample of the output has
    /// local `t = 0.15` and corresponds to the master cursor position at
    /// `timelineRange.start + 0.15`. The evaluator's first-sample clamp
    /// then holds that "predicted-future" anchor in place across the
    /// keyframe's ease-in window — exactly what gesture zooms want so the
    /// zoom ramps in already pointed at where the cursor is heading,
    /// not where the wiggle was. Default 0 preserves the original
    /// no-lookahead behavior for non-gesture keyframes.
    public static func window(
        _ master: [MouseTrajectorySample],
        timelineRange: TimeRange,
        leadSeconds: Double = 0
    ) -> [ZoomTrajectorySample] {
        let start = timelineRange.start.seconds
        let duration = timelineRange.duration.seconds
        guard duration > 0 else { return [] }
        let lead = max(0.0, leadSeconds)
        let sliceStart = start + lead
        let end = start + duration
        guard sliceStart <= end else { return [] }
        return master.compactMap { sample -> ZoomTrajectorySample? in
            guard sample.timelineTime >= sliceStart, sample.timelineTime <= end else { return nil }
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

    /// Per-sample deceleration confidence in `[0, 1]`, aligned to
    /// `trajectory`'s indices. Drives the decel-gated lookahead on
    /// `anchorFollow`: when confidence is high the camera leans toward
    /// the cursor's predicted landing zone; at 0 it behaves like a plain
    /// deadzone follow. Same formula as the editor's `IntentScorer.sDecel`
    /// (the signal that decides which clicks earn an auto-zoom keyframe)
    /// so the "intent" signal that fires keyframes and the one that
    /// biases framing agree by construction.
    ///
    /// Mirror lives in `IntentScorer.decelConfidence(trajectory:)` —
    /// reproduces this output bit-for-bit. The duplication is intentional:
    /// PixelbayPlayback cannot depend on PixelbayEditor, so the core
    /// helper lives here and the editor calls into it. Constants
    /// (`decelWindow = 0.5 s`, `decelDropFullScale = 0.35 norm/s`) match
    /// IntentScorer so a single tuning pass updates both consumers.
    ///
    /// At index `i` the value is the normalised drop from the trajectory's
    /// peak smoothed velocity over `[t_i - decelWindow, t_i]` down to the
    /// current sample's velocity, divided by `decelDropFullScale` and
    /// clamped to `[0, 1]`. A constant-velocity sweep produces 0; a clean
    /// decel-to-rest produces values approaching 1 right at the landing
    /// point — which is exactly where the camera should already be
    /// pointed before the cursor finishes settling.
    public static func decelConfidence(
        _ trajectory: [MouseTrajectorySample],
        decelWindow: Double = 0.5,
        decelDropFullScale: Double = 0.35
    ) -> [Double] {
        guard trajectory.count >= 2 else {
            return Array(repeating: 0.0, count: trajectory.count)
        }
        let v = boxSmoothedVelocity(trajectory)
        var out = [Double](repeating: 0.0, count: trajectory.count)
        let windowSafe = max(0.001, decelWindow)
        let scaleSafe = max(1e-6, decelDropFullScale)
        for i in 0..<trajectory.count {
            let t = trajectory[i].timelineTime
            let start = t - windowSafe
            var maxV = 0.0
            var atV = 0.0
            var found = false
            for j in 0..<trajectory.count {
                let tj = trajectory[j].timelineTime
                if tj < start { continue }
                if tj > t { break }
                found = true
                if v[j] > maxV { maxV = v[j] }
                atV = v[j]
            }
            if !found { continue }
            let drop = max(0.0, maxV - atV)
            out[i] = max(0.0, min(1.0, drop / scaleSafe))
        }
        return out
    }

    /// Per-sample instantaneous velocity (norm-units/s), box-smoothed
    /// with a ±2-sample window (~5 samples, ~165 ms at 30 Hz). Mirrors
    /// `IntentScorer.computeSmoothedVelocity` byte-for-byte so the
    /// in-Core decel-confidence reproduces the editor's intent scoring.
    static func boxSmoothedVelocity(_ trajectory: [MouseTrajectorySample]) -> [Double] {
        guard trajectory.count >= 2 else {
            return Array(repeating: 0.0, count: trajectory.count)
        }
        var raw: [Double] = [0]
        raw.reserveCapacity(trajectory.count)
        for i in 1..<trajectory.count {
            let p = trajectory[i - 1]
            let s = trajectory[i]
            let dt = s.timelineTime - p.timelineTime
            guard dt > 0 else { raw.append(raw[i - 1]); continue }
            let dx = s.centerX - p.centerX
            let dy = s.centerY - p.centerY
            raw.append((dx * dx + dy * dy).squareRoot() / dt)
        }
        var smoothed = [Double](repeating: 0.0, count: raw.count)
        for i in 0..<raw.count {
            let lo = max(0, i - 2)
            let hi = min(raw.count - 1, i + 2)
            var sum = 0.0
            for k in lo...hi { sum += raw[k] }
            smoothed[i] = sum / Double(hi - lo + 1)
        }
        return smoothed
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
    public static func smoothstep(_ edge0: Double, _ edge1: Double, _ x: Double) -> Double {
        guard edge1 > edge0 else { return x < edge0 ? 0 : 1 }
        let t = min(1.0, max(0.0, (x - edge0) / (edge1 - edge0)))
        return t * t * (3.0 - 2.0 * t)
    }

    /// Lightweight one-pole EMA for the cursor *sprite* path — decoupled
    /// from the camera's `cameraDamped` so the sprite can move at near-real
    /// speed while the camera glides on the longer-τ velocity-adaptive
    /// spring (Screen Studio / Loom pattern). Default `tau = 0.02 s`
    /// settles within ~0.06 s — kills 60–120 Hz capture jitter without
    /// adding a perceptible lag on the click moment, where the previous
    /// shared `cameraDamped` path bled τ ≈ 0.05 s of lag into the sprite
    /// even at the precise-click regime.
    ///
    /// dt-aware alpha (`1 - exp(-dt/tau)`) so the smoother behaves
    /// consistently across capture rates and is robust to the ~30 Hz vs
    /// ~120 Hz mode that macOS event coalescing toggles between mid-sweep.
    /// Output preserves `timelineTime`; only `centerX / centerY` change.
    /// The sprite path's downstream consumer is the Catmull-Rom sampler in
    /// `PixelbayVideoCompositor.sampleCursorTrajectory`, which expects raw
    /// (not spring-damped) samples — feeding the lightly-EMA-smoothed
    /// trajectory there preserves the snap on direction changes that the
    /// Catmull-Rom interp gets credit for.
    public static func spriteSmoothed(
        _ master: [MouseTrajectorySample],
        tau: Double = 0.02
    ) -> [MouseTrajectorySample] {
        guard master.count > 1 else { return master }
        let safeTau = max(0.001, tau)
        var result: [MouseTrajectorySample] = []
        result.reserveCapacity(master.count)
        var x = master[0].centerX
        var y = master[0].centerY
        var prevT = master[0].timelineTime
        result.append(master[0])
        for i in 1..<master.count {
            let sample = master[i]
            let dt = max(0.0, sample.timelineTime - prevT)
            if dt <= 0 {
                result.append(MouseTrajectorySample(
                    timelineTime: sample.timelineTime,
                    centerX: x,
                    centerY: y
                ))
                continue
            }
            let alpha = 1.0 - exp(-dt / safeTau)
            x += alpha * (sample.centerX - x)
            y += alpha * (sample.centerY - y)
            prevT = sample.timelineTime
            result.append(MouseTrajectorySample(
                timelineTime: sample.timelineTime,
                centerX: x,
                centerY: y
            ))
        }
        return result
    }

    /// Deadzone-aware critically-damped spring that pulls the zoom anchor
    /// toward the (already-smoothed) cursor position. Two-stage model
    /// chosen specifically to fix the "cursor in slow motion" failure
    /// mode of the previous tight-tracking iteration — without a
    /// deadzone, the anchor follows the cursor every frame and the
    /// cursor visually freezes in the viewport while the world scrolls
    /// past. The deadzone restores the Screen-Studio look where the
    /// cursor moves naturally inside a central region and the camera
    /// only pans when the cursor approaches the edge.
    ///
    /// Default mode (`deadzoneFraction = 0`) is a **boundary-adaptive
    /// soft spring**: the spring is always engaged, pulling the anchor
    /// toward the cursor across the entire viewport, with τ ramping by
    /// distance to the safe-zone wall. Near the centre τ is `tauRelaxed`
    /// (0.08 s by default — Phase 3d tightening from the old 0.18 s, which
    /// produced visible cursor lead during in-zoom pans); near the safe-
    /// zone wall τ tightens to `tauTight` (0.04 s — snappy catch-up before
    /// the cursor escapes the safe zone). Safe zone shrunk to 50 % in
    /// Phase 3d (was 80 %) so the boundary-tight τ engages earlier as the
    /// cursor approaches the edge — cursor never reaches the viewport wall
    /// during in-zoom motion.
    /// Opting into a non-zero `deadzoneFraction` carves out an inner
    /// no-force region — see below for the geometry when that's used.
    ///
    /// `h_safe = (safeZoneFraction / 2) / max(1, zoomFactor)` is the
    /// hard safe-zone boundary; cursor must never exit the central
    /// `safeZoneFraction` of the visible viewport. After each substep
    /// the anchor is clamped to `cursor ± h_safe` if the spring couldn't
    /// catch up — failsafe for capture-rate dropouts and synthetic
    /// teleports.
    ///
    /// Opt-in deadzone (`deadzoneFraction > 0`): an inner radius
    /// `h_dead = (deadzoneFraction / 2) / max(1, zoomFactor)` becomes a
    /// no-force region; anchor velocity damps to zero inside, cursor
    /// moves freely within the viewport, spring engages only past the
    /// deadzone edge. The spring target then becomes
    /// `cursor − h_dead` in the cursor's direction, so the rest state
    /// is "cursor at the deadzone boundary" — continuous gradient with
    /// no discontinuity at the boundary. The boundary-adaptive τ ramp
    /// in this mode spans the *active band* `[h_dead, h_safe]` instead
    /// of `[0, h_safe]`. Used by callers that want explicit calm-frame
    /// behaviour over soft tracking.
    ///
    /// `lookaheadSeconds` + `lookaheadConfidence` (optional) shift the
    /// spring target forward along the cursor's instantaneous velocity:
    /// `target = cursor + velocity · lookaheadSeconds · confidence[i]`.
    /// Pass `lookaheadConfidence = nil` for a fixed-strength prediction
    /// (confidence = 1 at every sample). Pass a same-length array of
    /// `[0, 1]` values (typically from `IntentScorer`'s deceleration
    /// signal) to gate prediction on per-sample confidence — at 0 the
    /// behaviour is identical to a no-lookahead follow. The cursor's
    /// actual position is still used for the hard-barrier safe-zone
    /// invariant, so a wrong prediction (cursor changes direction
    /// mid-decel) still cannot exceed the safe zone.
    ///
    /// τ ramp inside the active band:
    ///   `e = max(|cx-ax|, |cy-ay|) − h_dead) / (h_safe − h_dead)`,
    ///   clamped to `[0, 1]`. Then
    ///   `τ(e) = tauRelaxed + (tauTight − tauRelaxed) · e`.
    ///
    /// Hard barrier: after each sample's substep loop, if the anchor
    /// would fall outside the safe zone, clamp to the wall and zero
    /// that axis's velocity. Failsafe for capture-rate dropouts and
    /// synthetic teleports the spring couldn't catch up to.
    ///
    /// Output shape: same `[ZoomTrajectorySample]` as input, same `t`
    /// values; only `(x, y)` is rewritten. Catmull-Rom downstream
    /// (`EffectEvaluator.zoomCenter`) consumes it unchanged.
    ///
    /// Pinned (gesture) keyframes bypass this entirely upstream — they
    /// want the anchor locked, not following. `.pinned` remains a
    /// valid mode for back-compat (legacy v4 sidecars decode through
    /// it) and for future explicit-pin workflows.
    public static func anchorFollow(
        _ samples: [ZoomTrajectorySample],
        zoomFactor: Double,
        deadzoneFraction: Double = 0.0,
        safeZoneFraction: Double = 0.50,
        tauRelaxed: Double = 0.08,
        tauTight: Double = 0.04,
        lookaheadSeconds: Double = 0.0,
        lookaheadConfidence: [Double]? = nil
    ) -> [ZoomTrajectorySample] {
        guard let first = samples.first else { return [] }
        guard samples.count > 1 else { return samples }
        let safeZoom = max(1.0, zoomFactor)
        let safeFrac = min(0.99, max(0.05, safeZoneFraction))
        let deadFrac = min(safeFrac - 0.02, max(0.0, deadzoneFraction))
        let safeTauRelaxed = max(0.01, tauRelaxed)
        let safeTauTight = max(0.005, min(safeTauRelaxed, tauTight))
        let hSafe = (safeFrac / 2.0) / safeZoom
        let hDead = (deadFrac / 2.0) / safeZoom
        let activeBand = max(1e-9, hSafe - hDead)
        let safeLookahead = max(0.0, lookaheadSeconds)
        var anchorX = first.x
        var anchorY = first.y
        var vx: Double = 0
        var vy: Double = 0
        var prevT: Double = first.t
        var result: [ZoomTrajectorySample] = []
        result.reserveCapacity(samples.count)
        result.append(first)
        for i in 1..<samples.count {
            let s = samples[i]
            let prev = samples[i - 1]
            let dtTotal = max(0.0, s.t - prevT)
            if dtTotal <= 0 {
                result.append(ZoomTrajectorySample(t: s.t, x: anchorX, y: anchorY))
                continue
            }
            // Per-sample cursor velocity from the *cursor* trajectory (not
            // the anchor's). Used by the lookahead term to shift the spring
            // target forward along the cursor's heading. Confidence ∈ [0,1]
            // gates how aggressively we predict — at 0, lookahead vanishes
            // and we behave exactly like the plain deadzone follow.
            let cursorVx: Double
            let cursorVy: Double
            if dtTotal > 0 {
                cursorVx = (s.x - prev.x) / dtTotal
                cursorVy = (s.y - prev.y) / dtTotal
            } else {
                cursorVx = 0
                cursorVy = 0
            }
            let conf: Double = {
                guard let arr = lookaheadConfidence else { return 1.0 }
                guard i < arr.count else { return 0.0 }
                return max(0.0, min(1.0, arr[i]))
            }()
            let leadX = cursorVx * safeLookahead * conf
            let leadY = cursorVy * safeLookahead * conf
            var remaining = dtTotal
            while remaining > 0 {
                // Spring target offset: cursor (+ lookahead·v·conf) offset
                // minus the deadzone radius in the cursor's direction.
                // Inside the deadzone the target offset is zero, so the
                // spring exerts no force — anchor velocity damps to a stop.
                let dxRaw = (s.x + leadX) - anchorX
                let dyRaw = (s.y + leadY) - anchorY
                let targetDx = abs(dxRaw) > hDead ? dxRaw - copysign(hDead, dxRaw) : 0
                let targetDy = abs(dyRaw) > hDead ? dyRaw - copysign(hDead, dyRaw) : 0
                // Adaptive τ: ramps from relaxed (just past deadzone) to
                // tight (at safe-zone wall). Continuous in cursor
                // position so there's no velocity step at the deadzone
                // boundary.
                let exOuter = max(0.0, abs(dxRaw) - hDead) / activeBand
                let eyOuter = max(0.0, abs(dyRaw) - hDead) / activeBand
                let eOuter = min(1.0, max(exOuter, eyOuter))
                let tau = safeTauRelaxed + (safeTauTight - safeTauRelaxed) * eOuter
                let omega = 1.0 / tau
                let stiffness = omega * omega
                let damping = 2.0 * omega
                let maxStep = tau * 0.25
                let step = min(maxStep, remaining)
                let ax = stiffness * targetDx - damping * vx
                let ay = stiffness * targetDy - damping * vy
                vx += ax * step
                vy += ay * step
                anchorX += vx * step
                anchorY += vy * step
                remaining -= step
            }
            // Hard barrier: enforce the safe-zone invariant even when
            // the spring couldn't catch up in the available `dtTotal`.
            let dx = s.x - anchorX
            if dx > hSafe {
                anchorX = s.x - hSafe
                vx = 0
            } else if dx < -hSafe {
                anchorX = s.x + hSafe
                vx = 0
            }
            let dy = s.y - anchorY
            if dy > hSafe {
                anchorY = s.y - hSafe
                vy = 0
            } else if dy < -hSafe {
                anchorY = s.y + hSafe
                vy = 0
            }
            prevT = s.t
            result.append(ZoomTrajectorySample(t: s.t, x: anchorX, y: anchorY))
        }
        return result
    }
}
