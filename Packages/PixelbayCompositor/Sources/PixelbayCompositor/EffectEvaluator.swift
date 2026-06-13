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
//   - For .zoom: compute the OpenScreen-style focus transform from the
//     keyframe's cursor focus, zoom factor, and animated progress. The
//     compositor then spring-smooths that per-frame camera target.
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
        let focus = clampFocusToScale(
            x: center.x,
            y: center.y,
            zoomScale: factorAtFullStrength
        )
        let transform = computeReferenceZoomTransform(
            stageSize: layout.outputSize,
            baseScreen: screen,
            zoomScale: factorAtFullStrength,
            progress: strength,
            focusX: focus.x,
            focusY: focus.y
        )

        var next = layout
        next.screen = LayerRect(
            origin: CGPoint(
                x: screen.origin.x * CGFloat(transform.scale) + CGFloat(transform.x),
                y: screen.origin.y * CGFloat(transform.scale) + CGFloat(transform.y)
            ),
            size: CGSize(
                width: screen.size.width * CGFloat(transform.scale),
                height: screen.size.height * CGFloat(transform.scale)
            )
        )
        return next
    }

    private static func clampFocusToScale(
        x: Double,
        y: Double,
        zoomScale: Double
    ) -> (x: Double, y: Double) {
        let margin = min(0.5, 1.0 / (2.0 * max(1.0, zoomScale)))
        return (
            x: min(max(x, margin), 1.0 - margin),
            y: min(max(y, margin), 1.0 - margin)
        )
    }

    private static func computeReferenceZoomTransform(
        stageSize: CGSize,
        baseScreen: LayerRect,
        zoomScale: Double,
        progress: Double,
        focusX: Double,
        focusY: Double
    ) -> AppliedZoomTransform {
        let p = min(1.0, max(0.0, progress))
        let focusStageX = Double(baseScreen.origin.x + baseScreen.size.width * CGFloat(focusX))
        let focusStageY = Double(baseScreen.origin.y + baseScreen.size.height * CGFloat(focusY))
        let stageCenterX = Double(stageSize.width) / 2.0
        let stageCenterY = Double(stageSize.height) / 2.0
        let scale = 1.0 + (zoomScale - 1.0) * p
        let finalX = stageCenterX - focusStageX * zoomScale
        let finalY = stageCenterY - focusStageY * zoomScale
        return AppliedZoomTransform(scale: scale, x: finalX * p, y: finalY * p)
    }

    /// Per-frame zoom centre: the cursor-follow path, sampled at `t` during
    /// the ease windows too. The target focus is already distance-adaptive
    /// and frame-rate-independent; the compositor's zoom spring then removes
    /// velocity discontinuities from the camera transform itself.
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
