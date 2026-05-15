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
    /// Global ceiling on the radial-blur strength fed to the screen shader.
    /// Even at peak mid-ease the kernel only spreads ~2.5 % of the radius —
    /// just enough to soften the in/out feel without UI text smearing into
    /// itself. Was 0.06 originally, dropped after user feedback that zoom
    /// transitions read as "too blurry"; 0.025 keeps the motion-softening
    /// cue while leaving fine UI strokes legible mid-ease.
    static let screenZoomBlurMaxStrength: Double = 0.025

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
            // Per-frame radial motion-blur intensity for the screen layer.
            // 4·s·(1−s) is a smooth bump centred at s = 0.5 — zero at hold
            // (s = 1) and idle (s = 0), peaks mid-ease where the framing is
            // changing fastest. Multiplied by a global cap so the effect
            // stays subtle (a heavy blur reads as "broken playback" rather
            // than "smooth motion").
            let easeProgress = winner.strength
            let bump = 4.0 * easeProgress * (1.0 - easeProgress)
            let center = zoomCenter(for: winner.kf, atTime: t)
            layout.screenZoomBlurStrength = Float(max(0.0, min(1.0, bump)) * Self.screenZoomBlurMaxStrength)
            layout.screenZoomBlurCenterUV = SIMD2(
                Float(max(0.0, min(1.0, center.x))),
                Float(max(0.0, min(1.0, center.y)))
            )
        }

        for kf in keyframes where kf.kind == .talkingHeadSwap {
            let strength = kf.strength(at: t)
            guard strength > 0 else { continue }
            layout = applyTalkingHead(strength: strength, to: layout)
        }
        return layout
    }

    private static func applyZoom(
        _ kf: EffectKeyframe,
        strength: Double,
        atTime t: Double,
        to layout: ResolvedLayout
    ) -> ResolvedLayout {
        let factorAtFullStrength = max(1.0, kf.zoomFactor)
        let factor = 1.0 + (factorAtFullStrength - 1.0) * strength
        guard factor > 1.0001 else { return layout }

        let screen = layout.screen
        let center = zoomCenter(for: kf, atTime: t)
        let cx = max(0, min(1, center.x))
        let cy = max(0, min(1, center.y))

        let newWidth = screen.size.width * CGFloat(factor)
        let newHeight = screen.size.height * CGFloat(factor)
        // Place the zoomed rect so the cursor (cx, cy) — in source-fraction
        // space — sits at the visual centre of the original screen rect.
        // Then clamp so the (larger) rect still fully covers the original;
        // when the cursor approaches an edge the rect snaps so the edge
        // aligns, instead of revealing black past the screen.
        let targetX = screen.minX + screen.size.width / 2
        let targetY = screen.minY + screen.size.height / 2
        let unclampedX = targetX - newWidth * CGFloat(cx)
        let unclampedY = targetY - newHeight * CGFloat(cy)
        let minOriginX = screen.maxX - newWidth
        let minOriginY = screen.maxY - newHeight
        let newOriginX = max(minOriginX, min(screen.minX, unclampedX))
        let newOriginY = max(minOriginY, min(screen.minY, unclampedY))

        var next = layout
        next.screen = LayerRect(
            origin: CGPoint(x: newOriginX, y: newOriginY),
            size: CGSize(width: newWidth, height: newHeight)
        )
        return next
    }

    /// Per-frame zoom centre. When the keyframe carries a non-empty
    /// `trajectory`, the centre follows it via non-uniform Catmull-Rom
    /// (Barry-Goldman) across `(t, x, y)` waypoints (keyframe-local time,
    /// `t=0` at `timelineRange.start`). Non-uniform parameterisation is
    /// load-bearing — captured trajectory samples are unevenly spaced in
    /// time (CGEventTap is event-driven, macOS coalesces under load), and
    /// uniform Catmull-Rom on those gaps produces velocity overshoots at
    /// each spacing change that read as jitter at zoom factors ≥ 1.5×.
    /// With only ≤ 2 samples (no outer neighbours available) falls back
    /// to linear; at the trajectory's first / last segment the missing
    /// outer neighbour is mirrored from the boundary sample. The lookup
    /// `t` is clamped to `[first.t, last.t]` so we never extrapolate.
    /// Falls back to the static `(centerX, centerY)` for manually-
    /// authored keyframes (`trajectory == nil`) and for the empty-
    /// explicit sentinel the slice-2 auto-zoom path can emit
    /// (`trajectory == []`).
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
        if localT <= firstSample.t {
            return (firstSample.x, firstSample.y)
        }
        if localT >= lastSample.t {
            return (lastSample.x, lastSample.y)
        }
        // Linear scan is fine — auto-zoom segments are short (≤ a few seconds
        // at 120 Hz → hundreds of samples max). Switch to binary search if
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
