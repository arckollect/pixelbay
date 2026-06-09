import CoreGraphics
import Foundation
import PixelbayCore

// Phase 3b — pure-data evaluator that applies the active EffectKeyframes
// (zoom, talking-head swap) to a `ResolvedLayout` at a given playhead
// position. Lives in PixelbayCompositor (not the editor) because it
// produces a per-frame geometry the render graph consumes directly.
//
// Per-frame contract:
//   - Walk the keyframe array, skip those whose strength(at: t) is 0.
//   - For .zoom: multiply the screen rect by `1 + (zoomFactor - 1) * s`,
//     then position the rect so (centerX, centerY) lands at the visual
//     centre of the original screen rect — clamped so the larger rect
//     still fully covers the original (no black gaps at the edges).
//     Equivalent to CSS object-fit: cover with a focal point.
//   - For .talkingHeadSwap: the webcam rect is reparented onto the screen
//     rect with `webcamOpacity = s`, so the webcam crossfades in on top of
//     the still-rendered screen layer as the keyframe's strength ramps
//     0 → 1. The original PiP webcam slot vanishes the moment the keyframe
//     becomes active; at s = 1 the webcam fully obscures the screen. If
//     the recording had no webcam in the first place, talking-head is a
//     no-op (nothing to swap in).
//
// Output: a new ResolvedLayout. The caller (PixelbayVideoCompositor)
// passes this to MetalRenderGraph just like a static layout.

public enum EffectEvaluator {
    /// Phase 3d transition-blur peak sigma in pixels. Driven by the eased
    /// strength bell `4·s·(1−s)` so it ramps `0 → peak → 0` across each
    /// ease window, hits 0 during held zoom and off-keyframe. Replaces
    /// the Phase 3c camera-velocity radial blur for the *transition*
    /// portion — Gaussian, not radial, so it reads as a soft veil rather
    /// than a warp.
    static let screenZoomBlurPeakSigmaPx: Double = 2.25

    /// Follow-pan motion blur is DIRECTIONAL (along the camera's velocity
    /// vector) and velocity-proportional: blur half-extent in layer-UV is
    /// `cameraSpeed · panBlurShutterSeconds`, gated by a smoothstep onset
    /// so slow drifts stay crisp, then scaled by the keyframe's eased
    /// strength and the user's Motion Blur multiplier. Held-zoom with a
    /// stationary cursor still reads as 0 (no blur), preserving crisp
    /// paused frames.
    ///
    /// `panBlurShutterSeconds` is the synthetic exposure window — 1/50 s
    /// makes a deliberate follow (~0.5 norm/s) streak ~1 % of the layer
    /// and a fast chase visibly smear along the motion direction.
    /// `panBlurMaxUV` caps the half-extent so even a teleport-fast pan
    /// stays readable.
    static let panBlurShutterSeconds: Double = 1.0 / 50.0
    static let panBlurMaxUV: Double = 0.030

    /// Camera-speed onset ramp for the pan blur, in norm-units/sec on the
    /// camera's anchor-waypoint velocity. Below threshold the camera is
    /// treated as still (no blur); by `panBlurFullSpeed` the blur is fully
    /// proportional to speed. Raised from 0.06/0.30 so the slow
    /// anticipatory pre-drift (the camera easing toward a sweep's
    /// destination before the cursor commits) stays crisp — blur builds
    /// only once the pan is actually fast.
    static let panBlurThresholdSpeed: Double = 0.12
    static let panBlurFullSpeed: Double = 0.60

    public static func apply(
        keyframes: [EffectKeyframe],
        baseLayout: ResolvedLayout,
        atTime t: Double
    ) -> ResolvedLayout {
        var layout = baseLayout

        // Single-zoom-winner: at any frame, at most one `.zoom` keyframe
        // applies — the one whose `strength(at:)` is highest, with ties
        // broken by latest `timelineRange.start` (so a freshly-engaged zoom
        // wins over one that's fading out). This is the L4 backstop for
        // documents on disk that may still hold overlapping zoom keyframes
        // (the L2/L3 editor-side fixes prevent NEW overlap, but pre-existing
        // bundles aren't migrated). Without this, two overlapping
        // `zoomFactor=1.6` keyframes would compose to ~2.56× zoom in the
        // overlap — the "weird zoom-ins" the user reported.
        //
        // `.talkingHeadSwap` keyframes affect webcam opacity, not screen
        // zoom; multiple don't compound destructively, so the original
        // per-keyframe loop is preserved for that kind.
        var winner: (kf: EffectKeyframe, strength: Double)?
        for kf in keyframes where kf.kind == .zoom {
            let strength = kf.strength(at: t)
            guard strength > 0 else { continue }
            if let current = winner {
                let beatsByStrength = strength > current.strength
                let tieBrokenByLatest = strength == current.strength
                    && kf.timelineRange.start.seconds > current.kf.timelineRange.start.seconds
                if beatsByStrength || tieBrokenByLatest {
                    winner = (kf, strength)
                }
            } else {
                winner = (kf, strength)
            }
        }
        if let winner {
            layout = applyZoom(winner.kf, strength: winner.strength, atTime: t, to: layout)
            // Two blur terms, naturally exclusive by construction (the zoom
            // centre is locked during the ease windows, so the camera only
            // moves during hold — when the bell is 0):
            //   • Transition bell: isotropic Gaussian, peaks mid-ease and
            //     resolves crisp at hold (Phase 3d).
            //   • Pan blur: DIRECTIONAL streak along the camera's velocity,
            //     half-extent proportional to camera speed (synthetic
            //     shutter), so fast cursor-follow pans read as real motion
            //     blur — the faster the pan, the longer the streak — while
            //     held-zoom-with-stationary-cursor stays bit-identical to
            //     no blur.
            // Both terms scale with the keyframe's eased strength (no
            // hard-cut blur pop at t = keyframe.start) and the user's
            // Motion Blur multiplier.
            let bell = max(0.0, 4.0 * winner.strength * (1.0 - winner.strength))
            let transitionSigma = bell
                * Self.screenZoomBlurPeakSigmaPx
                * winner.kf.zoomFollowMotionBlur
            let (vx, vy) = zoomCameraVelocity(for: winner.kf, atTime: t)
            let cameraSpeed = (vx * vx + vy * vy).squareRoot()
            let panRamp = MouseTrajectory.smoothstep(
                Self.panBlurThresholdSpeed,
                Self.panBlurFullSpeed,
                cameraSpeed
            )
            let panHalfExtentUV = min(
                Self.panBlurMaxUV,
                cameraSpeed * Self.panBlurShutterSeconds
                    * panRamp
                    * winner.strength
                    * winner.kf.zoomFollowMotionBlur
            )
            if cameraSpeed > 1e-9, panHalfExtentUV > 1e-5 {
                layout.screenMotionBlurUV = SIMD2(
                    Float(vx / cameraSpeed * panHalfExtentUV),
                    Float(vy / cameraSpeed * panHalfExtentUV)
                )
            }
            layout.screenZoomBlurSigmaPx = Float(transitionSigma)
        }

        for kf in keyframes where kf.kind == .talkingHeadSwap {
            let strength = kf.strength(at: t)
            guard strength > 0 else { continue }
            layout = applyTalkingHead(strength: strength, to: layout)
        }
        return layout
    }

    // Edge-aware framing constants. When the raw anchor sits inside the
    // 15 % `deadzone` margin, `frameAnchor` blends it toward the screen
    // centre so the cursor doesn't slide all the way into a corner of the
    // zoomed frame; a deep-corner anchor additionally backs the zoom factor
    // off. The hard clamp below stays as a safety net.
    private static let edgeDeadzone: Double = 0.15
    private static let edgeBlendStrength: Double = 0.6
    private static let cornerCutoff: Double = 0.08
    private static let cornerFactorScale: Double = 0.7

    private static func applyZoom(
        _ kf: EffectKeyframe,
        strength: Double,
        atTime t: Double,
        to layout: ResolvedLayout
    ) -> ResolvedLayout {
        let factorAtFullStrength = max(1.0, kf.zoomFactor)
        guard factorAtFullStrength > 1.0001, strength > 1e-6 else { return layout }

        let screen = layout.screen
        let center = zoomCenter(for: kf, atTime: t)
        let rawCx = max(0, min(1, center.x))
        let rawCy = max(0, min(1, center.y))
        // Edge-blending only applies to STATIC anchors (pinned-gesture marks,
        // single-click auto-zooms with no trajectory). Cursor-following
        // zooms keep the raw anchor — the natural clamp below produces the
        // snap-to-edge framing that keeps the cursor visible at viewport
        // edges. Blending toward centre on cursor-follow would shift the
        // rect just inside the clamp and render the cursor sprite outside
        // the visible viewport.
        let isCursorFollow = kf.anchorMode != .pinned
            && (kf.trajectory?.isEmpty == false)
        let (cx, cy, factorAtFull): (Double, Double, CGFloat)
        if isCursorFollow {
            (cx, cy, factorAtFull) = (rawCx, rawCy, CGFloat(factorAtFullStrength))
        } else {
            (cx, cy, factorAtFull) = frameAnchor(rawCx: rawCx, rawCy: rawCy, baseFactor: CGFloat(factorAtFullStrength))
        }

        // currentFactor must use the (possibly corner-backed-off) factorAtFull,
        // not the raw zoomFactor — otherwise the deep-corner backoff is
        // silently overridden by the linear strength ramp.
        let currentFactor = 1.0 + (Double(factorAtFull) - 1.0) * strength
        guard currentFactor > 1.0001 else { return layout }

        // Phase 3d — interpolate the cursor's screen position, not the rect
        // origin. The old path applied `currentFactor` to the rect size
        // then clamped the origin to fit the viewport; at low zoom factors
        // (early in ease-in) the clamp was so tight that even a "centred"
        // computation barely moved the cursor's screen position — the
        // cursor would stay near its pre-zoom location until the rect grew
        // enough to loosen the clamp, then "snap" toward the framed
        // position. With this lerp the cursor glides smoothly from its
        // natural unzoomed screen position to its fully-framed position
        // over the ease curve.
        //
        // 1. Compute the cursor's screen position at FULL zoom (where it
        //    lands at strength=1, fully clamped to keep the rect inside
        //    the viewport).
        let framedWidth = screen.size.width * factorAtFull
        let framedHeight = screen.size.height * factorAtFull
        let viewportCenterX = screen.minX + screen.size.width / 2
        let viewportCenterY = screen.minY + screen.size.height / 2
        let framedUnclampedOriginX = viewportCenterX - framedWidth * CGFloat(cx)
        let framedUnclampedOriginY = viewportCenterY - framedHeight * CGFloat(cy)
        let framedMinOriginX = screen.maxX - framedWidth
        let framedMinOriginY = screen.maxY - framedHeight
        let framedOriginX = max(framedMinOriginX, min(screen.minX, framedUnclampedOriginX))
        let framedOriginY = max(framedMinOriginY, min(screen.minY, framedUnclampedOriginY))
        let framedCursorX = framedOriginX + framedWidth * CGFloat(cx)
        let framedCursorY = framedOriginY + framedHeight * CGFloat(cy)

        // 2. Natural cursor position at strength=0 (no zoom): cursor sits
        //    at (cx, cy) within the original screen rect.
        let naturalCursorX = screen.minX + screen.size.width * CGFloat(cx)
        let naturalCursorY = screen.minY + screen.size.height * CGFloat(cy)

        // 3. Lerp via the keyframe's eased strength.
        let s = CGFloat(strength)
        let currentCursorX = naturalCursorX + (framedCursorX - naturalCursorX) * s
        let currentCursorY = naturalCursorY + (framedCursorY - naturalCursorY) * s

        // 4. Size the rect at currentFactor and place it so the cursor
        //    lands at the interpolated screen position. Apply the safe-
        //    coverage clamp as a no-op safety net (it shouldn't bite at
        //    strength=0 or strength=1 by construction; intermediate
        //    strengths stay inside the convex hull of those endpoints).
        let newWidth = screen.size.width * CGFloat(currentFactor)
        let newHeight = screen.size.height * CGFloat(currentFactor)
        let unclampedOriginX = currentCursorX - newWidth * CGFloat(cx)
        let unclampedOriginY = currentCursorY - newHeight * CGFloat(cy)
        let minOriginX = screen.maxX - newWidth
        let minOriginY = screen.maxY - newHeight
        let newOriginX = max(minOriginX, min(screen.minX, unclampedOriginX))
        let newOriginY = max(minOriginY, min(screen.minY, unclampedOriginY))

        var next = layout
        next.screen = LayerRect(
            origin: CGPoint(x: newOriginX, y: newOriginY),
            size: CGSize(width: newWidth, height: newHeight)
        )
        return next
    }

    /// Edge-aware anchor blending: when the raw anchor sits in the 15 %
    /// deadzone near an edge, pull it toward the screen centre with strength
    /// 0.6 at the very edge tapering to 0 at the deadzone boundary. In a
    /// deep corner (within 8 % on both axes) additionally back the zoom
    /// factor off by `cornerFactorScale`. Without this, a corner click would
    /// hit the hard clamp and the cursor would visibly slide to a corner of
    /// the zoomed frame; with it, the cursor stays near (not exactly at)
    /// frame centre and the framing feels deliberate.
    private static func frameAnchor(
        rawCx: Double,
        rawCy: Double,
        baseFactor: CGFloat
    ) -> (cx: Double, cy: Double, factor: CGFloat) {
        func axisBlend(_ v: Double) -> Double {
            let dEdge = min(v, 1 - v)
            guard dEdge < edgeDeadzone else { return v }
            let t = dEdge / edgeDeadzone           // 1 at boundary, 0 at edge
            let pull = edgeBlendStrength * (1 - t) // 0 outside, 0.6 at edge
            return v + (0.5 - v) * pull
        }
        let cx = axisBlend(rawCx)
        let cy = axisBlend(rawCy)
        let inCornerX = min(rawCx, 1 - rawCx) < cornerCutoff
        let inCornerY = min(rawCy, 1 - rawCy) < cornerCutoff
        let factor = (inCornerX && inCornerY)
            ? max(1.0, 1.0 + (baseFactor - 1.0) * cornerFactorScale)
            : baseFactor
        return (cx, cy, factor)
    }

    /// Per-frame zoom centre.
    ///
    /// Phase 3d: the centre is **locked** during the ease-in and ease-out
    /// windows. The ease windows now drive a deliberate rect-growth-in-
    /// place feel (paired with the screen-position lerp in `applyZoom`):
    ///   - Ease-in: hold at `trajectory[0]` (cursor-at-trigger). The
    ///     viewer sees the framing rect grow around the click point.
    ///   - Hold (middle): non-uniform Catmull-Rom along trajectory — the
    ///     camera follows live cursor motion via the post-anchorFollow
    ///     anchor positions.
    ///   - Ease-out: hold at `trajectory[last]` (cursor at the moment
    ///     ease-out begins, give or take a few ms). The framing rect
    ///     shrinks back to 1× without the centre drifting.
    ///
    /// The earlier always-Catmull-Rom behaviour caused the focal point to
    /// wobble while the rect was still small (low zoom factor), which
    /// read as "the zoom doesn't centre on the cursor — it lands there
    /// last-second." Locking the centre during the ease windows eliminates
    /// that wobble: the only motion during the transition comes from the
    /// strength lerp.
    ///
    /// Catmull-Rom (held middle): non-uniform Barry-Goldman across `(t, x,
    /// y)` waypoints. Non-uniform parameterisation is load-bearing —
    /// captured trajectory samples are unevenly spaced in time (CGEventTap
    /// is event-driven, macOS coalesces under load), and uniform Catmull-
    /// Rom on those gaps produces velocity overshoots at each spacing
    /// change that read as jitter at zoom factors ≥ 1.5×. With only ≤ 2
    /// samples (no outer neighbours available) falls back to linear; at
    /// the trajectory's first / last segment the missing outer neighbour
    /// is mirrored from the boundary sample.
    ///
    /// Falls back to the static `(centerX, centerY)` for manually-authored
    /// keyframes (`trajectory == nil`) and for the empty-explicit sentinel
    /// the slice-2 auto-zoom path can emit (`trajectory == []`).
    private static func zoomCenter(
        for kf: EffectKeyframe,
        atTime t: Double
    ) -> (x: Double, y: Double) {
        // Pinned keyframes always render at (centerX, centerY), regardless of
        // whatever `trajectory` happens to hold. Belt-and-braces against any
        // future code path that writes a trajectory into a pinned keyframe;
        // the primary defence lives in PreviewComposition.applyCursorTrajectory
        // (which skips pinned at composition build time), but the contract
        // belongs in the evaluator too — anyone reading this code should be
        // able to see the static-centre guarantee at the point it's rendered.
        if kf.anchorMode == .pinned {
            return (kf.centerX, kf.centerY)
        }
        guard let trajectory = kf.trajectory, !trajectory.isEmpty else {
            return (kf.centerX, kf.centerY)
        }
        let localT = t - kf.timelineRange.start.seconds
        let firstSample = trajectory[0]
        let lastSample = trajectory[trajectory.count - 1]

        // Phase 3d centre-lock during the ease windows. The keyframe's
        // ease-in / ease-out durations are inside the keyframe's range, so
        // localT < easeIn  → still ramping up      → lock to first sample.
        // localT > range − easeOut → ramping back down → lock to last sample.
        // Hold (middle) → sample the trajectory normally below.
        let (inEnd, outStart) = easeLockBounds(for: kf)
        if localT <= max(firstSample.t, inEnd) {
            return (firstSample.x, firstSample.y)
        }
        if localT >= min(lastSample.t, outStart) {
            return (lastSample.x, lastSample.y)
        }

        // Hold portion — non-uniform Catmull-Rom along trajectory. Linear
        // scan is fine: auto-zoom segments are short (≤ a few seconds at
        // 120 Hz → hundreds of samples max). Switch to binary search if
        // profiles ever say otherwise.
        for i in 1..<trajectory.count {
            let b = trajectory[i]
            if localT <= b.t {
                let a = trajectory[i - 1]
                let span = b.t - a.t
                if span <= 0 { return (b.x, b.y) }
                if trajectory.count <= 2 {
                    let u = (localT - a.t) / span
                    return (a.x + (b.x - a.x) * u, a.y + (b.y - a.y) * u)
                }
                let p0 = (i - 2) >= 0 ? trajectory[i - 2] : a
                let p3 = (i + 1) < trajectory.count ? trajectory[i + 1] : b
                return nonUniformCatmullRom2D(
                    p0t: p0.t, p0x: p0.x, p0y: p0.y,
                    p1t: a.t, p1x: a.x, p1y: a.y,
                    p2t: b.t, p2x: b.x, p2y: b.y,
                    p3t: p3.t, p3x: p3.x, p3y: p3.y,
                    at: localT
                )
            }
        }
        return (lastSample.x, lastSample.y)
    }

    /// Effective ease-window bounds in keyframe-local seconds, shared by
    /// `zoomCenter`'s centre-lock and `zoomCameraVelocity`'s blur gating so
    /// the two regimes can never drift apart. `inEnd` is where the ease-in
    /// lock releases; `outStart` is where the ease-out lock engages. Ease
    /// durations that overflow the keyframe's range are proportionally
    /// shrunk, mirroring `EffectKeyframe.strength(at:)`.
    private static func easeLockBounds(for kf: EffectKeyframe) -> (inEnd: Double, outStart: Double) {
        let total = kf.timelineRange.end.seconds - kf.timelineRange.start.seconds
        let easeIn = max(0.0, kf.easeIn.seconds)
        let easeOut = max(0.0, kf.easeOut.seconds)
        let easeBudget = easeIn + easeOut
        let inEff: Double
        let outEff: Double
        if easeBudget > total, total > 0 {
            let scale = total / easeBudget
            inEff = easeIn * scale
            outEff = easeOut * scale
        } else {
            inEff = easeIn
            outEff = easeOut
        }
        return (inEff, total - outEff)
    }

    /// Camera velocity (norm-units/s in screen-content space) driving the
    /// pan motion blur. Derived from the anchor trajectory's own waypoints
    /// — a ±2-segment box average of per-segment velocities — rather than
    /// finite-differencing the Catmull-Rom-interpolated `zoomCenter`, which
    /// had two visible failure modes:
    ///   • the spline's local curvature wiggles between 30 Hz waypoints, so
    ///     a 1/60 s derivative points in noise directions during slow drift
    ///     (the "blur direction is random" report);
    ///   • differencing across the ease-lock boundary returned the entire
    ///     ease window's accumulated anchor displacement in one frame — a
    ///     massive fake speed spike right as the zoom settled (the "blur
    ///     before the movement even starts" report).
    /// Returns zero while the displayed centre is locked (ease windows,
    /// same bounds as `zoomCenter` via `easeLockBounds`) and for pinned /
    /// trajectory-less keyframes — no displayed pan, no blur, by
    /// construction. Near-zero-Δt segments (scenes-merge boundaries place
    /// two samples at the same timeline time) are skipped so a scene cut
    /// can't masquerade as an infinite-speed pan.
    private static func zoomCameraVelocity(
        for kf: EffectKeyframe,
        atTime t: Double
    ) -> (vx: Double, vy: Double) {
        if kf.anchorMode == .pinned { return (0, 0) }
        guard let trajectory = kf.trajectory, trajectory.count >= 2 else { return (0, 0) }
        let localT = t - kf.timelineRange.start.seconds
        let firstSample = trajectory[0]
        let lastSample = trajectory[trajectory.count - 1]
        let (inEnd, outStart) = easeLockBounds(for: kf)
        if localT <= max(firstSample.t, inEnd) { return (0, 0) }
        if localT >= min(lastSample.t, outStart) { return (0, 0) }
        // Bracketing segment: segment i spans [t_i, t_{i+1}].
        var bracket = trajectory.count - 2
        for i in 1..<trajectory.count where localT <= trajectory[i].t {
            bracket = i - 1
            break
        }
        var sumVx = 0.0
        var sumVy = 0.0
        var count = 0
        let lo = max(0, bracket - 2)
        let hi = min(trajectory.count - 2, bracket + 2)
        for i in lo...hi {
            let a = trajectory[i]
            let b = trajectory[i + 1]
            let dt = b.t - a.t
            guard dt > 1e-4 else { continue }
            sumVx += (b.x - a.x) / dt
            sumVy += (b.y - a.y) / dt
            count += 1
        }
        guard count > 0 else { return (0, 0) }
        return (sumVx / Double(count), sumVy / Double(count))
    }

    private static func applyTalkingHead(
        strength: Double,
        to layout: ResolvedLayout
    ) -> ResolvedLayout {
        // Recordings with no webcam: nothing to swap in.
        guard layout.webcam != nil else { return layout }
        let clamped = max(0.0, min(1.0, strength))
        var next = layout
        next.webcam = layout.screen
        next.webcamOpacity = Float(clamped)
        return next
    }
}
