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
    /// Applies the active effect keyframes at time `t`, plus TRUE temporal
    /// motion blur: when `shutterSeconds > 0`, the camera transform is also
    /// evaluated at `t ± shutter/2` and packed into the layout as source-UV
    /// remappings (`screenUVOpen` / `screenUVClose`). The fragment shader
    /// samples the same source frame under N transforms interpolated
    /// between them and averages — like a real camera shutter. Pan blur
    /// during follow, radial blur during the zoom scale change, and curved-
    /// path blur all fall out of the transform delta with no separate
    /// heuristics; a still camera collapses to a single tap.
    ///
    /// `shutterSeconds` is the caller-computed exposure window — typically
    /// `frameDuration · shutterAngle/360 · blurStrength` from the project's
    /// motion tuning. `transitionSoftness` blends the zoom in/out strength
    /// curve toward a longer-tailed ease (see `EffectKeyframe.strength`).
    public static func apply(
        keyframes: [EffectKeyframe],
        baseLayout: ResolvedLayout,
        atTime t: Double,
        shutterSeconds: Double = 0,
        transitionSoftness: Double = 0
    ) -> ResolvedLayout {
        var layout = applyAtInstant(
            keyframes: keyframes, baseLayout: baseLayout, atTime: t,
            transitionSoftness: transitionSoftness
        )

        if shutterSeconds > 1e-6 {
            let half = shutterSeconds / 2
            let rectNow = layout.screen
            let rectOpen = applyAtInstant(
                keyframes: keyframes, baseLayout: baseLayout, atTime: t - half,
                transitionSoftness: transitionSoftness
            ).screen
            let rectClose = applyAtInstant(
                keyframes: keyframes, baseLayout: baseLayout, atTime: t + half,
                transitionSoftness: transitionSoftness
            ).screen
            layout.screenUVOpen = uvTransform(from: rectNow, to: rectOpen)
            layout.screenUVClose = uvTransform(from: rectNow, to: rectClose)
        }
        return layout
    }

    /// The instantaneous layout at time `t` — winner-takes-all zoom plus
    /// talking-head swaps, no blur bookkeeping. Called once for the frame
    /// itself and (when temporal blur is on) once each for the shutter-open
    /// and shutter-close instants.
    private static func applyAtInstant(
        keyframes: [EffectKeyframe],
        baseLayout: ResolvedLayout,
        atTime t: Double,
        transitionSoftness: Double = 0
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
            let strength = kf.strength(at: t, transitionSoftness: transitionSoftness)
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
        }

        for kf in keyframes where kf.kind == .talkingHeadSwap {
            let strength = kf.strength(at: t)
            guard strength > 0 else { continue }
            layout = applyTalkingHead(strength: strength, to: layout)
        }
        return layout
    }

    /// Source-UV remapping between two drawn rects. For an output pixel
    /// whose texCoord is `uv` under `rect`, the same output pixel under
    /// `other` has texCoord `uv * result.xy + result.zw`. Identity when the
    /// rects match.
    static func uvTransform(from rect: LayerRect, to other: LayerRect) -> SIMD4<Float> {
        guard other.size.width > 0, other.size.height > 0 else {
            return ResolvedLayout.identityUVTransform
        }
        let scaleX = rect.size.width / other.size.width
        let scaleY = rect.size.height / other.size.height
        let offsetX = (rect.origin.x - other.origin.x) / other.size.width
        let offsetY = (rect.origin.y - other.origin.y) / other.size.height
        return SIMD4<Float>(Float(scaleX), Float(scaleY), Float(offsetX), Float(offsetY))
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
    /// Short centre handoff after ease-in. The zoom scale reaches 100% at the
    /// end of the ease window; if the follow trajectory moved while the centre
    /// was locked, jumping to that trajectory on the next frame reads as a
    /// last-second placement snap. Blend the focal point onto the live path
    /// over a handful of frames instead.

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

    /// Per-frame zoom centre: the LIVE camera path, sampled at `t` — during
    /// the ease windows too. The zoom-in tracks the (already buttery)
    /// glide-follow camera as it ramps instead of freezing at the trigger
    /// point and snapping to the live path afterwards; the old ease-lock +
    /// centre-handoff machinery existed to hide wobble from near-raw
    /// trajectories, which the shared click-pinned smoothed path and the
    /// constant-weight camera spring eliminated at the source. Ease-out
    /// glides the same way: the trajectory's last sample (where the camera
    /// came to rest) holds the centre while the rect shrinks.
    ///
    /// Catmull-Rom sampling: non-uniform Barry-Goldman across `(t, x, y)`
    /// waypoints. Non-uniform parameterisation is load-bearing — captured
    /// trajectory samples are unevenly spaced in time (CGEventTap is
    /// event-driven, macOS coalesces under load), and uniform Catmull-Rom
    /// on those gaps produces velocity overshoots at each spacing change
    /// that read as jitter at zoom factors ≥ 1.5×. With only ≤ 2 samples
    /// (no outer neighbours available) falls back to linear.
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
        return sampledZoomCenter(in: trajectory, at: t - kf.timelineRange.start.seconds)
    }

    private static func sampledZoomCenter(
        in trajectory: [ZoomTrajectorySample],
        at localT: Double
    ) -> (x: Double, y: Double) {
        guard let first = trajectory.first else { return (0.5, 0.5) }
        guard let last = trajectory.last else { return (first.x, first.y) }
        if localT <= first.t { return (first.x, first.y) }
        if localT >= last.t { return (last.x, last.y) }
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
        return (last.x, last.y)
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
