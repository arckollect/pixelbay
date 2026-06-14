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

    /// Per-sample deceleration confidence in `[0, 1]`, aligned to
    /// `trajectory`'s indices. Drives the decel-gated lookahead on
    /// `anchorFollow`: when confidence is high the camera leans toward
    /// the cursor's predicted landing zone; at 0 it behaves like a plain
    /// slack follow. Same formula as the editor's `IntentScorer.sDecel`
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

    // Note: the velocity-adaptive `cameraDamped` filter was retired in the
    // motion-tuning overhaul. Its core flaw: it made the camera SNAPPIER
    // the faster the cursor moved (tau tightened with speed), which read
    // as panic on fast sweeps. The camera now keeps one constant weight at
    // every speed (`glideFollow`), and fast input is tamed upstream by the
    // shared `clickPinnedSmoothed` path instead.

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

    // Note: the old `spritePolished` zero-phase polish was superseded by
    // `clickPinnedSmoothed` below — same windowed-average core, plus click
    // pinning and a tunable amplitude-collapse allowance instead of a fixed
    // deviation cap.

    private static func instantaneousSpeeds(_ trajectory: [MouseTrajectorySample]) -> [Double] {
        guard trajectory.count > 1 else { return Array(repeating: 0, count: trajectory.count) }
        var speeds = [Double](repeating: 0.0, count: trajectory.count)
        for i in trajectory.indices {
            if i == trajectory.startIndex {
                let next = trajectory[trajectory.index(after: i)]
                let dt = max(1e-6, next.timelineTime - trajectory[i].timelineTime)
                let dx = next.centerX - trajectory[i].centerX
                let dy = next.centerY - trajectory[i].centerY
                speeds[i] = (dx * dx + dy * dy).squareRoot() / dt
            } else if i == trajectory.index(before: trajectory.endIndex) {
                let prev = trajectory[trajectory.index(before: i)]
                let dt = max(1e-6, trajectory[i].timelineTime - prev.timelineTime)
                let dx = trajectory[i].centerX - prev.centerX
                let dy = trajectory[i].centerY - prev.centerY
                speeds[i] = (dx * dx + dy * dy).squareRoot() / dt
            } else {
                let prev = trajectory[trajectory.index(before: i)]
                let next = trajectory[trajectory.index(after: i)]
                let dtPrev = max(1e-6, trajectory[i].timelineTime - prev.timelineTime)
                let dxPrev = trajectory[i].centerX - prev.centerX
                let dyPrev = trajectory[i].centerY - prev.centerY
                let prevSpeed = (dxPrev * dxPrev + dyPrev * dyPrev).squareRoot() / dtPrev
                let dtNext = max(1e-6, next.timelineTime - trajectory[i].timelineTime)
                let dxNext = next.centerX - trajectory[i].centerX
                let dyNext = next.centerY - trajectory[i].centerY
                let nextSpeed = (dxNext * dxNext + dyNext * dyNext).squareRoot() / dtNext
                speeds[i] = max(prevSpeed, nextSpeed)
            }
        }
        return speeds
    }

    /// THE shared cursor path: zero-phase smoothing with amplitude collapse
    /// and pixel-exact click pinning (Screen Studio's post-production cursor
    /// rewrite). Both the rendered cursor sprite AND the zoom camera's
    /// target consume this one path — sharing it is what makes the camera
    /// feel effortless: it never sees violent raw motion, because the input
    /// was tamed upstream.
    ///
    /// Three behaviors compose per sample:
    ///
    /// **Zero-phase window average.** Each output blends the raw point with
    /// a centered triangular time-window average (half-width
    /// `windowSeconds`), gated by instantaneous speed — hover and slow
    /// precise motion stay raw (no lag, clicks align), fast motion smooths.
    ///
    /// **Amplitude collapse.** The window average doesn't just slow fast
    /// motion, it *shrinks* it: rapid edge-to-edge spam mostly cancels
    /// inside the window, leaving a small graceful drift. `travelCollapse`
    /// controls how far the smoothed path may deviate from raw during fast
    /// travel — at 0 deviation is pinned tight (path stays honest), at 1
    /// fast spam may fully collapse toward the window mean.
    ///
    /// **Click pinning.** At every `clickTimes` entry the output is exactly
    /// the raw position, with the smoothing easing back in over
    /// `clickSnapWindow` seconds on both sides — stylized travel between
    /// clicks, pixel-accurate interaction at them.
    ///
    /// The window never averages across a scenes-merge boundary (adjacent
    /// samples ≤ 1 ms apart but > 5 % of the screen apart), so the path
    /// can't smear across a scene cut.
    ///
    /// Output is same-length, same `timelineTime`s; only x/y rewritten.
    public static func clickPinnedSmoothed(
        _ master: [MouseTrajectorySample],
        windowSeconds: Double,
        travelCollapse: Double,
        clickTimes: [Double] = [],
        clickSnapWindow: Double = 0.15,
        speedLow: Double = 0.05,
        speedHigh: Double = 0.60
    ) -> [MouseTrajectorySample] {
        guard master.count > 2, windowSeconds > 0.001 else { return master }
        let window = windowSeconds
        let collapse = min(1.0, max(0.0, travelCollapse))
        let snap = max(0.01, clickSnapWindow)
        let sortedClicks = clickTimes.sorted()
        let speeds = instantaneousSpeeds(master)
        // Deviation allowance during fast travel. The floor keeps slow-ish
        // motion visually honest even at collapse = 1; the ceiling lets
        // edge-to-edge spam (raw deviation ~0.5 norm-units from the window
        // mean) collapse completely.
        let minDeviation = 0.02
        let maxDeviationCeiling = 0.50

        var result: [MouseTrajectorySample] = []
        result.reserveCapacity(master.count)
        for i in master.indices {
            let sample = master[i]
            // Endpoints are smoothed too (with a truncated, one-sided
            // window) rather than passed through raw — a raw endpoint
            // against a heavily stylized neighbor reads as a cursor jump
            // at every clip boundary. Speed gating already keeps a
            // stationary recording start/end honest.
            let speedBlend = smoothstep(speedLow, speedHigh, speeds[i])
            guard speedBlend > 0 else {
                result.append(sample)
                continue
            }
            // Triangular window walk, stopping at scenes-merge boundaries.
            var sumX = 0.0
            var sumY = 0.0
            var sumW = 0.0
            func accumulate(_ s: MouseTrajectorySample) {
                let w = max(0.0, 1.0 - abs(s.timelineTime - sample.timelineTime) / window)
                guard w > 0 else { return }
                sumX += s.centerX * w
                sumY += s.centerY * w
                sumW += w
            }
            accumulate(sample)
            var j = i - 1
            while j >= 0 {
                if master[j].timelineTime < sample.timelineTime - window { break }
                if isMergeBoundary(master[j], master[j + 1]) { break }
                accumulate(master[j])
                j -= 1
            }
            j = i + 1
            while j < master.count {
                if master[j].timelineTime > sample.timelineTime + window { break }
                if isMergeBoundary(master[j - 1], master[j]) { break }
                accumulate(master[j])
                j += 1
            }
            guard sumW > 0 else {
                result.append(sample)
                continue
            }
            var smoothX = sumX / sumW
            var smoothY = sumY / sumW
            // Amplitude collapse: allow deviation from raw proportional to
            // speed and the collapse strength.
            let dx = smoothX - sample.centerX
            let dy = smoothY - sample.centerY
            let deviation = (dx * dx + dy * dy).squareRoot()
            let maxDeviation = minDeviation
                + (maxDeviationCeiling - minDeviation) * collapse * speedBlend
            if deviation > maxDeviation, deviation > 0 {
                let scale = maxDeviation / deviation
                smoothX = sample.centerX + dx * scale
                smoothY = sample.centerY + dy * scale
            }
            var outX = sample.centerX + (smoothX - sample.centerX) * speedBlend
            var outY = sample.centerY + (smoothY - sample.centerY) * speedBlend
            // Click pinning: exactly raw at the click instant, smoothstep
            // ease back to the stylized path over the snap window.
            let pin = clickPinWeight(at: sample.timelineTime, clicks: sortedClicks, snapWindow: snap)
            if pin > 0 {
                outX += (sample.centerX - outX) * pin
                outY += (sample.centerY - outY) * pin
            }
            result.append(MouseTrajectorySample(
                timelineTime: sample.timelineTime,
                centerX: outX,
                centerY: outY
            ))
        }
        return result
    }

    /// Pin weight in `[0, 1]` — 1 exactly at a click, smoothstep falloff
    /// to 0 at `snapWindow` away from the nearest click. `clicks` must be
    /// sorted ascending.
    static func clickPinWeight(
        at time: Double,
        clicks: [Double],
        snapWindow: Double
    ) -> Double {
        guard !clicks.isEmpty else { return 0 }
        // Binary search for the nearest click.
        var lo = 0
        var hi = clicks.count - 1
        while lo < hi {
            let mid = (lo + hi) / 2
            if clicks[mid] < time { lo = mid + 1 } else { hi = mid }
        }
        var nearest = abs(clicks[lo] - time)
        if lo > 0 { nearest = min(nearest, abs(clicks[lo - 1] - time)) }
        return 1.0 - smoothstep(0.0, snapWindow, nearest)
    }

    /// Scenes-merge boundary check for master-trajectory samples — same
    /// constants as the keyframe-local `isMergeBoundary` below.
    private static func isMergeBoundary(
        _ a: MouseTrajectorySample,
        _ b: MouseTrajectorySample
    ) -> Bool {
        guard b.timelineTime - a.timelineTime <= 0.001 else { return false }
        let dx = b.centerX - a.centerX
        let dy = b.centerY - a.centerY
        return (dx * dx + dy * dy) > (0.05 * 0.05)
    }

    /// True when two adjacent trajectory samples straddle a scenes-merge
    /// boundary: near-zero time delta with a non-trivial position delta.
    /// Same constants as the compositor's sprite-path detector.
    private static func isMergeBoundary(
        _ a: ZoomTrajectorySample,
        _ b: ZoomTrajectorySample
    ) -> Bool {
        guard b.t - a.t <= 0.001 else { return false }
        let dx = b.x - a.x
        let dy = b.y - a.y
        return (dx * dx + dy * dy) > (0.05 * 0.05)
    }

    /// The zoom camera: a heavy, CONSTANT-weight glide with a true deadzone
    /// and a soft full recenter. This is the Screen Studio camera feel —
    /// the camera never changes character with cursor speed (the retired
    /// `anchorFollow` tightened its spring as the cursor sped up, which
    /// read as panic on fast sweeps). Fast input is tamed upstream by the
    /// shared `clickPinnedSmoothed` path; this stage adds only weight.
    ///
    /// **State machine.** The camera is either *resting* (perfectly still)
    /// or *gliding*:
    ///   • Resting: while the cursor stays within `deadzoneFraction` of
    ///     the visible zoomed half-extent, the camera does not move at all
    ///     — typing and small clicks leave the framing rock solid.
    ///   • Gliding: once the cursor commits past the deadzone, the camera
    ///     glides until the cursor is back near CENTER frame (soft full
    ///     recenter — like a camera operator re-framing), then rests
    ///     again. Spring strength ramps in over ~200 ms on engagement so
    ///     there's never a kick.
    ///
    /// **Spring.** Critically-damped-to-elastic depending on `settle`
    /// (dampingRatio = 1 − 0.45·settle): at 0 the camera approaches its
    /// target with zero overshoot; at 1 it drifts slightly past a landing
    /// and eases back — felt weight, never bounce. `cameraTau` is the one
    /// time constant, identical at every cursor speed. `maxPanSpeed` caps
    /// velocity during integration (inertia preserved, not position-
    /// clamped). `edgeCushion` adds preemptive catch-up pressure near the
    /// visible viewport edge before the hard safety clamp has to intervene.
    /// `lookaheadSeconds` aims the spring at the path's actual future
    /// position (rendering is post-hoc — the future is known).
    ///
    /// The emergency visible-frame clamp (cursor can never leave the
    /// zoomed viewport) and the scenes-merge boundary snap are preserved
    /// from the previous camera unchanged.
    ///
    /// Output shape: same `[ZoomTrajectorySample]`, same `t`s; only (x, y)
    /// rewritten. Pinned (gesture) keyframes bypass this upstream.
    public static func glideFollow(
        _ samples: [ZoomTrajectorySample],
        zoomFactor: Double,
        cameraTau: Double = 0.35,
        settle: Double = 0.25,
        deadzoneFraction: Double = 0.35,
        edgeCushion: Double = 0.55,
        maxPanSpeed: Double = 0.9,
        lookaheadSeconds: Double = 0.0
    ) -> [ZoomTrajectorySample] {
        guard let first = samples.first else { return [] }
        guard samples.count > 1 else { return samples }
        let safeZoom = max(1.0, zoomFactor)
        let visibleHalfExtent = 0.48 / safeZoom
        let deadzoneRadius = min(0.95, max(0.0, deadzoneFraction)) * visibleHalfExtent
        // Rest only once the camera has genuinely re-centered: a quarter
        // of the deadzone (or a hair above zero when there is no deadzone,
        // so a stopped cursor still lets the camera fall fully asleep).
        let restRadius = max(0.004, 0.25 * deadzoneRadius)
        let restCursorSpeed = 0.08
        let restCameraSpeed = 0.05
        let tau = max(0.02, cameraTau)
        let dampingRatio = 1.0 - 0.45 * min(1.0, max(0.0, settle))
        let omega = 1.0 / tau
        let stiffness = omega * omega
        let damping = 2.0 * dampingRatio * omega
        let cushion = min(1.0, max(0.0, edgeCushion))
        let speedLimit = maxPanSpeed.isFinite ? max(0.0, maxPanSpeed) : .infinity
        let lookahead = max(0.0, lookaheadSeconds)
        let engageRampSeconds = 0.2

        var anchorX = first.x
        var anchorY = first.y
        var vx: Double = 0
        var vy: Double = 0
        var prevT: Double = first.t
        var isResting = true
        var engagement: Double = 0
        var result: [ZoomTrajectorySample] = []
        result.reserveCapacity(samples.count)
        result.append(first)

        func capVector(_ x: inout Double, _ y: inout Double, to limit: Double) {
            guard limit.isFinite else { return }
            let magnitude = (x * x + y * y).squareRoot()
            guard magnitude > limit, magnitude > 0 else { return }
            let scale = limit / magnitude
            x *= scale
            y *= scale
        }

        func enforceVisibleFrame(cursorX: Double, cursorY: Double) {
            let dx = cursorX - anchorX
            let dy = cursorY - anchorY
            let distance = (dx * dx + dy * dy).squareRoot()
            guard distance > visibleHalfExtent, distance > 1e-9 else { return }
            let unitX = dx / distance
            let unitY = dy / distance
            anchorX = cursorX - unitX * visibleHalfExtent
            anchorY = cursorY - unitY * visibleHalfExtent
            // Keep useful tangential/inward momentum, but remove outward
            // velocity that would immediately push the cursor out again.
            let radialVelocity = vx * unitX + vy * unitY
            if radialVelocity < 0 {
                vx -= radialVelocity * unitX
                vy -= radialVelocity * unitY
            }
            capVector(&vx, &vy, to: speedLimit)
        }

        func edgePressure(cursorX: Double, cursorY: Double) -> Double {
            guard cushion > 0 else { return 0 }
            let dx = cursorX - anchorX
            let dy = cursorY - anchorY
            let distance = (dx * dx + dy * dy).squareRoot()
            let start = visibleHalfExtent * (1.0 - 0.75 * cushion)
            return MouseTrajectory.smoothstep(start, visibleHalfExtent, distance)
        }

        /// The path's actual position `lookahead` seconds after sample
        /// `index` (linear interp; clamps at the end; never reads across a
        /// scenes-merge boundary).
        func lookaheadTarget(from index: Int) -> (x: Double, y: Double) {
            guard lookahead > 0 else { return (samples[index].x, samples[index].y) }
            let targetT = samples[index].t + lookahead
            var j = index
            while j + 1 < samples.count, samples[j + 1].t <= targetT {
                if isMergeBoundary(samples[j], samples[j + 1]) {
                    return (samples[j].x, samples[j].y)
                }
                j += 1
            }
            guard j + 1 < samples.count,
                  !isMergeBoundary(samples[j], samples[j + 1])
            else { return (samples[j].x, samples[j].y) }
            let a = samples[j]
            let b = samples[j + 1]
            let span = b.t - a.t
            guard span > 1e-9 else { return (a.x, a.y) }
            let f = (targetT - a.t) / span
            return (a.x + (b.x - a.x) * f, a.y + (b.y - a.y) * f)
        }

        for i in 1..<samples.count {
            let s = samples[i]
            let prev = samples[i - 1]
            let dtTotal = max(0.0, s.t - prevT)
            if dtTotal <= 0 {
                // Scenes-merge defense: ScenesMerger places clips back-to-
                // back, so scene N's last sample and scene N+1's first land
                // at the same timeline time with potentially very different
                // cursor positions. SNAP the camera to the new position and
                // reset state so cross-scene steps never bleed into the
                // spring as fake velocity. Same-timestamp samples with a
                // small delta (clock quantization inside one recording)
                // pass through untouched.
                let dx = s.x - anchorX
                let dy = s.y - anchorY
                if (dx * dx + dy * dy) > (0.05 * 0.05) {
                    anchorX = s.x
                    anchorY = s.y
                    vx = 0
                    vy = 0
                    isResting = true
                    engagement = 0
                    prevT = s.t
                }
                result.append(ZoomTrajectorySample(t: s.t, x: anchorX, y: anchorY))
                continue
            }
            let cursorSpeed = {
                let dx = (s.x - prev.x) / dtTotal
                let dy = (s.y - prev.y) / dtTotal
                return (dx * dx + dy * dy).squareRoot()
            }()
            let distToCursor = {
                let dx = s.x - anchorX
                let dy = s.y - anchorY
                return (dx * dx + dy * dy).squareRoot()
            }()

            if isResting {
                if distToCursor > deadzoneRadius {
                    isResting = false
                    engagement = 0
                } else {
                    enforceVisibleFrame(cursorX: s.x, cursorY: s.y)
                    prevT = s.t
                    result.append(ZoomTrajectorySample(t: s.t, x: anchorX, y: anchorY))
                    continue
                }
            }

            // Gliding: full recenter onto the (lookahead-shifted) cursor.
            let target = lookaheadTarget(from: i)
            var remaining = dtTotal
            let maxStep = tau * 0.20
            while remaining > 0 {
                let step = min(maxStep, remaining)
                engagement = min(1.0, engagement + step / engageRampSeconds)
                // Smoothstep the engagement so the spring force fades in —
                // exiting the deadzone must never read as a kick.
                let engage = MouseTrajectory.smoothstep(0.0, 1.0, engagement)
                let pressure = edgePressure(cursorX: s.x, cursorY: s.y)
                let effectiveEngage = max(engage, pressure * cushion)
                let edgeBoost = 1.0 + 4.0 * pressure * cushion
                var ax = (stiffness * edgeBoost * (target.x - anchorX) - damping * vx) * effectiveEngage
                var ay = (stiffness * edgeBoost * (target.y - anchorY) - damping * vy) * effectiveEngage
                // Damping always acts at full strength on existing
                // velocity so the ramp can't leave momentum unmanaged.
                if effectiveEngage < 1.0 {
                    ax -= damping * vx * (1.0 - effectiveEngage)
                    ay -= damping * vy * (1.0 - effectiveEngage)
                }
                vx += ax * step
                vy += ay * step
                capVector(&vx, &vy, to: speedLimit)
                anchorX += vx * step
                anchorY += vy * step
                remaining -= step
            }
            enforceVisibleFrame(cursorX: s.x, cursorY: s.y)

            // Settle back to rest once the camera has re-centered, the
            // cursor has stopped committing, and any settle drift-past has
            // played out.
            let cameraSpeed = (vx * vx + vy * vy).squareRoot()
            let postDist = {
                let dx = s.x - anchorX
                let dy = s.y - anchorY
                return (dx * dx + dy * dy).squareRoot()
            }()
            if postDist < restRadius, cursorSpeed < restCursorSpeed, cameraSpeed < restCameraSpeed {
                isResting = true
                engagement = 0
                vx = 0
                vy = 0
            }

            prevT = s.t
            result.append(ZoomTrajectorySample(t: s.t, x: anchorX, y: anchorY))
        }
        return result
    }
}
