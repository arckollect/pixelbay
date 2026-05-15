import Foundation

// Shared interpolation helpers used by both the per-frame cursor-sprite
// path (`PixelbayVideoCompositor.sampleCursorTrajectory`) and the per-
// frame zoom-follow path (`EffectEvaluator.zoomCenter`).
//
// The captured cursor / mouse-move trajectory is *non-uniformly spaced
// in time* — CGEventTap delivers events at the system-native rate and
// macOS coalesces during fast cursor sweeps, so the gap between two
// consecutive samples can swing from 4 ms (browser idle) to 40 ms
// (full-screen sweep). A *uniform* Catmull-Rom kernel fed those samples
// would assume equal spacing in u and produce a velocity overshoot at
// every sample whose neighbour spacing changed — exactly the "looks
// like frames are skipped" stutter on fast cursor moves the user
// reported.
//
// The Barry-Goldman recursive Lagrange formulation below evaluates a
// non-uniform Catmull-Rom-equivalent cubic that respects each sample's
// actual time. Computed via three nested linear interpolations (so it
// stays numerically stable even when the time spans differ by orders
// of magnitude). At evenly-spaced t values it reduces to the standard
// uniform Catmull-Rom result.
//
// Both x and y are interpolated together because they share the same
// time parameter — saves recomputing the seven blend weights twice.

/// Non-uniform Catmull-Rom (Barry-Goldman) over four time-stamped 2D
/// samples. Returns the (x, y) pair on the interpolated cubic at time
/// `at`. Defined for the segment `t ∈ [p1t, p2t]`; outside that range
/// the output is still well-defined but the cubic extrapolates, so
/// callers should clamp lookups to the bracketing pair.
///
/// Degenerate-time-span guards: if any adjacent pair shares the same
/// timestamp (zero-span), that segment's blend collapses to the leading
/// sample. Without these the divisions would emit NaNs and the cursor
/// would teleport.
@inline(__always)
internal func nonUniformCatmullRom2D(
    p0t: Double, p0x: Double, p0y: Double,
    p1t: Double, p1x: Double, p1y: Double,
    p2t: Double, p2x: Double, p2y: Double,
    p3t: Double, p3x: Double, p3y: Double,
    at t: Double
) -> (x: Double, y: Double) {
    // First-level blends (p_{i-1}, p_i) → A_i for i=1,2,3.
    let a1x: Double, a1y: Double
    if p1t > p0t {
        let w = (t - p0t) / (p1t - p0t)
        a1x = lerp(p0x, p1x, w)
        a1y = lerp(p0y, p1y, w)
    } else {
        a1x = p1x; a1y = p1y
    }
    let a2x: Double, a2y: Double
    if p2t > p1t {
        let w = (t - p1t) / (p2t - p1t)
        a2x = lerp(p1x, p2x, w)
        a2y = lerp(p1y, p2y, w)
    } else {
        a2x = p2x; a2y = p2y
    }
    let a3x: Double, a3y: Double
    if p3t > p2t {
        let w = (t - p2t) / (p3t - p2t)
        a3x = lerp(p2x, p3x, w)
        a3y = lerp(p2y, p3y, w)
    } else {
        a3x = p3x; a3y = p3y
    }

    // Second-level blends (A_1, A_2) → B_1, (A_2, A_3) → B_2.
    let b1x: Double, b1y: Double
    if p2t > p0t {
        let w = (t - p0t) / (p2t - p0t)
        b1x = lerp(a1x, a2x, w)
        b1y = lerp(a1y, a2y, w)
    } else {
        b1x = a2x; b1y = a2y
    }
    let b2x: Double, b2y: Double
    if p3t > p1t {
        let w = (t - p1t) / (p3t - p1t)
        b2x = lerp(a2x, a3x, w)
        b2y = lerp(a2y, a3y, w)
    } else {
        b2x = a3x; b2y = a3y
    }

    // Final blend (B_1, B_2) → C.
    if p2t > p1t {
        let w = (t - p1t) / (p2t - p1t)
        return (lerp(b1x, b2x, w), lerp(b1y, b2y, w))
    } else {
        return (b2x, b2y)
    }
}

@inline(__always)
private func lerp(_ a: Double, _ b: Double, _ t: Double) -> Double {
    a + (b - a) * t
}
