import XCTest
import PixelbayCore
@testable import PixelbayCompositor

final class EffectEvaluatorTests: XCTestCase {

    private func baseLayout() -> ResolvedLayout {
        ResolvedLayout(
            outputSize: CGSize(width: 1920, height: 1080),
            background: .clear,
            screen: LayerRect(origin: .zero, size: CGSize(width: 1920, height: 1080)),
            screenCornerRadius: 0,
            webcam: LayerRect(
                origin: CGPoint(x: 1656, y: 921),
                size: CGSize(width: 240, height: 135)
            ),
            webcamShape: .rectangle,
            webcamCornerRadius: 12
        )
    }

    // MARK: - Zoom

    func test_apply_noKeyframes_returnsBaseLayoutUnchanged() {
        let base = baseLayout()
        let result = EffectEvaluator.apply(keyframes: [], baseLayout: base, atTime: 5)
        XCTAssertEqual(result, base)
    }

    func test_apply_zoomBeforeStart_doesNothing() {
        let base = baseLayout()
        let kf = EffectKeyframe(
            kind: .zoom,
            timelineRange: TimeRange(start: .seconds(5), duration: .seconds(2)),
            zoomFactor: 2.0
        )
        let result = EffectEvaluator.apply(keyframes: [kf], baseLayout: base, atTime: 1)
        XCTAssertEqual(result.screen, base.screen)
    }

    func test_apply_zoomAtFullStrength_scalesScreenAroundCenter() {
        let base = baseLayout()
        // Center-pointed zoom at full strength → 2× scale, centered on (0.5, 0.5).
        let kf = EffectKeyframe(
            kind: .zoom,
            timelineRange: TimeRange(start: .seconds(0), duration: .seconds(2)),
            zoomFactor: 2.0,
            centerX: 0.5,
            centerY: 0.5,
            easeIn: .seconds(0),
            easeOut: .seconds(0)
        )
        let result = EffectEvaluator.apply(keyframes: [kf], baseLayout: base, atTime: 1)
        XCTAssertEqual(result.screen.size.width, 3840, accuracy: 1)
        XCTAssertEqual(result.screen.size.height, 2160, accuracy: 1)
        // Centered around (960, 540) → new origin (-960, -540).
        XCTAssertEqual(result.screen.origin.x, -960, accuracy: 1)
        XCTAssertEqual(result.screen.origin.y, -540, accuracy: 1)
    }

    func test_apply_zoomAtTopLeftCenter_clampsFocusAndKeepsRequestedScale() {
        let base = baseLayout()
        // OpenScreen-style transform: focus is clamped to the visible
        // half-frame margin for the zoom scale, but the requested zoom scale
        // is preserved. At 2×, the focus margin is 0.25.
        let kf = EffectKeyframe(
            kind: .zoom,
            timelineRange: TimeRange(start: .seconds(0), duration: .seconds(2)),
            zoomFactor: 2.0,
            centerX: 0,
            centerY: 0,
            easeIn: .seconds(0),
            easeOut: .seconds(0)
        )
        let result = EffectEvaluator.apply(keyframes: [kf], baseLayout: base, atTime: 1)
        XCTAssertEqual(result.screen.size.width, 3840, accuracy: 1)
        XCTAssertEqual(result.screen.size.height, 2160, accuracy: 1)
        XCTAssertEqual(result.screen.origin.x, 0, accuracy: 1)
        XCTAssertEqual(result.screen.origin.y, 0, accuracy: 1)
    }

    func test_apply_zoomNearEdge_clampsSoRectStillCoversScreen() {
        let base = baseLayout()
        // Cursor at (0.9, 0.5) on a 1920×1080 screen at 2× zoom: target
        // would put the cursor at output (960, 540), but that pushes the
        // new rect's right edge inside the screen's right edge (gap → black).
        // Edge-clamp snaps the rect so its right edge = screen.maxX.
        let kf = EffectKeyframe(
            kind: .zoom,
            timelineRange: TimeRange(start: .seconds(0), duration: .seconds(2)),
            zoomFactor: 2.0,
            centerX: 0.9,
            centerY: 0.5,
            easeIn: .seconds(0),
            easeOut: .seconds(0)
        )
        let result = EffectEvaluator.apply(keyframes: [kf], baseLayout: base, atTime: 1)
        // newWidth = 3840 → origin clamps to screen.maxX - newWidth = -1920.
        XCTAssertEqual(result.screen.origin.x, -1920, accuracy: 1)
        // Y unclamped (centerY = 0.5): targetY=540, originY=540-2160*0.5=-540.
        XCTAssertEqual(result.screen.origin.y, -540, accuracy: 1)
    }

    func test_apply_zoomDuringEaseIn_partiallyScales() {
        let base = baseLayout()
        let kf = EffectKeyframe(
            kind: .zoom,
            timelineRange: TimeRange(start: .seconds(0), duration: .seconds(2)),
            zoomFactor: 2.0,
            easeIn: .seconds(0.5),
            easeOut: .seconds(0.5)
        )
        // Mid-easeIn (t=0.25) — strength should be somewhere in (0, 1).
        let result = EffectEvaluator.apply(keyframes: [kf], baseLayout: base, atTime: 0.25)
        XCTAssertGreaterThan(result.screen.size.width, base.screen.size.width)
        XCTAssertLessThan(result.screen.size.width, base.screen.size.width * 2)
    }

    // MARK: - OpenScreen Focus Transform

    func test_applyZoom_centerAnchor_unchanged() {
        // Regression guard: a centered anchor remains the identity focus case.
        let base = baseLayout()
        let kf = EffectKeyframe(
            kind: .zoom,
            timelineRange: TimeRange(start: .seconds(0), duration: .seconds(2)),
            zoomFactor: 2.0,
            centerX: 0.5,
            centerY: 0.5,
            easeIn: .seconds(0),
            easeOut: .seconds(0)
        )
        let result = EffectEvaluator.apply(keyframes: [kf], baseLayout: base, atTime: 1)
        XCTAssertEqual(result.screen.size.width, 3840, accuracy: 1)
        XCTAssertEqual(result.screen.size.height, 2160, accuracy: 1)
        XCTAssertEqual(result.screen.origin.x, -960, accuracy: 1)
        XCTAssertEqual(result.screen.origin.y, -540, accuracy: 1)
    }

    func test_applyZoom_edgeAnchor_clampsToVisibleFocusMargin() {
        // rawCx = 0.01 clamps to 0.25 at 2×, producing origin.x = 0.
        let base = baseLayout()
        let kf = EffectKeyframe(
            kind: .zoom,
            timelineRange: TimeRange(start: .seconds(0), duration: .seconds(2)),
            zoomFactor: 2.0,
            centerX: 0.01,
            centerY: 0.5,
            easeIn: .seconds(0),
            easeOut: .seconds(0)
        )
        let result = EffectEvaluator.apply(keyframes: [kf], baseLayout: base, atTime: 1)
        XCTAssertEqual(result.screen.size.width, 3840, accuracy: 1)
        XCTAssertEqual(result.screen.origin.x, 0, accuracy: 1.0)
    }

    func test_applyZoom_deepCorner_keepsRequestedScale() {
        // The reference does not reduce zoom scale in deep corners.
        let base = baseLayout()
        let kf = EffectKeyframe(
            kind: .zoom,
            timelineRange: TimeRange(start: .seconds(0), duration: .seconds(2)),
            zoomFactor: 2.0,
            centerX: 0.02,
            centerY: 0.02,
            easeIn: .seconds(0),
            easeOut: .seconds(0)
        )
        let result = EffectEvaluator.apply(keyframes: [kf], baseLayout: base, atTime: 1)
        XCTAssertEqual(result.screen.size.width, 3840, accuracy: 1)
        XCTAssertEqual(result.screen.size.height, 2160, accuracy: 1)
        XCTAssertEqual(result.screen.origin.x, 0, accuracy: 1)
        XCTAssertEqual(result.screen.origin.y, 0, accuracy: 1)
    }

    func test_applyZoom_insideVisibleMargin_clampsToMargin() {
        // rawCx = 0.20 is inside the 0.25 margin at 2×, so it clamps to 0.25.
        let base = baseLayout()
        let kf = EffectKeyframe(
            kind: .zoom,
            timelineRange: TimeRange(start: .seconds(0), duration: .seconds(2)),
            zoomFactor: 2.0,
            centerX: 0.20,
            centerY: 0.5,
            easeIn: .seconds(0),
            easeOut: .seconds(0)
        )
        let result = EffectEvaluator.apply(keyframes: [kf], baseLayout: base, atTime: 1)
        XCTAssertEqual(result.screen.size.width, 3840, accuracy: 1)
        XCTAssertEqual(result.screen.origin.x, 0, accuracy: 1)
    }

    func test_applyZoom_followCursor_atEdge_skipsBlendAndClampsCleanly() {
        // Follow-cursor zoom (trajectory present, anchorMode = .followCursor)
        // at the left source edge must NOT pull the anchor toward centre —
        // doing so leaves the framing rect just inside the clamp, which
        // renders the cursor sprite outside the visible viewport. The
        // correct snap-to-edge produces origin = 0 (rect's left edge aligns
        // with the viewport's left edge), so the cursor at source-frac 0
        // appears at the viewport's left edge — visible.
        let base = baseLayout()
        let kf = EffectKeyframe(
            kind: .zoom,
            timelineRange: TimeRange(start: .seconds(0), duration: .seconds(2)),
            zoomFactor: 2.0,
            centerX: 0.5,        // ignored when trajectory present
            centerY: 0.5,
            easeIn: .seconds(0),
            easeOut: .seconds(0),
            trajectory: [
                ZoomTrajectorySample(t: 0, x: 0.0, y: 0.5),
                ZoomTrajectorySample(t: 1, x: 0.0, y: 0.5),
                ZoomTrajectorySample(t: 2, x: 0.0, y: 0.5)
            ]
        )
        let result = EffectEvaluator.apply(keyframes: [kf], baseLayout: base, atTime: 1)
        // 2× zoom on 1920×1080 → newWidth = 3840. With cx = 0 (raw), the
        // rect would slide right by half its width to keep cx at viewport
        // centre; clamp snaps origin.x to 0 so the left edges align.
        XCTAssertEqual(result.screen.size.width, 3840, accuracy: 1)
        XCTAssertEqual(result.screen.origin.x, 0, accuracy: 1)
    }

    func test_applyZoom_pinnedAnchor_atCornerUsesReferenceClamp() {
        // Pinned/manual keyframes use the same focus transform as
        // cursor-follow keyframes.
        let base = baseLayout()
        let kf = EffectKeyframe(
            kind: .zoom,
            timelineRange: TimeRange(start: .seconds(0), duration: .seconds(2)),
            zoomFactor: 2.0,
            centerX: 0,
            centerY: 0,
            easeIn: .seconds(0),
            easeOut: .seconds(0),
            anchorMode: .pinned
        )
        let result = EffectEvaluator.apply(keyframes: [kf], baseLayout: base, atTime: 1)
        XCTAssertEqual(result.screen.size.width, 3840, accuracy: 1)
        XCTAssertEqual(result.screen.size.height, 2160, accuracy: 1)
        XCTAssertEqual(result.screen.origin.x, 0, accuracy: 1)
        XCTAssertEqual(result.screen.origin.y, 0, accuracy: 1)
    }

    // MARK: - Zoom trajectory

    /// Helper: zoom keyframe whose anchor (cx,cy) is well off the centre so
    /// the trajectory-override is visible in the output rect's origin.
    private func trajectoryZoomKeyframe(
        timelineStart: Double,
        duration: Double,
        trajectory: [ZoomTrajectorySample]?
    ) -> EffectKeyframe {
        EffectKeyframe(
            kind: .zoom,
            timelineRange: TimeRange(
                start: .seconds(timelineStart),
                duration: .seconds(duration)
            ),
            zoomFactor: 2.0,
            centerX: 0.5,
            centerY: 0.5,
            easeIn: .seconds(0),
            easeOut: .seconds(0),
            trajectory: trajectory
        )
    }

    /// Inverts the cursor-centred formula assuming the result was NOT
    /// edge-clamped: cx = (baseMid - originX) / newWidth. Callers must pass
    /// (cx, cy) in the safe range — for the 1920×1080 base at 2× this is
    /// roughly [0.25, 0.75]. Outside that, clamp triggers and the inverse
    /// loses information (multiple cx values share an origin).
    private func recoveredCenter(from result: ResolvedLayout, base: ResolvedLayout) -> (Double, Double) {
        let factorX = Double(result.screen.size.width) / Double(base.screen.size.width)
        let factorY = Double(result.screen.size.height) / Double(base.screen.size.height)
        let targetX = Double(base.screen.minX) + Double(base.screen.size.width) / 2
        let targetY = Double(base.screen.minY) + Double(base.screen.size.height) / 2
        let cx = (targetX - Double(result.screen.origin.x)) / (factorX * Double(base.screen.size.width))
        let cy = (targetY - Double(result.screen.origin.y)) / (factorY * Double(base.screen.size.height))
        return (cx, cy)
    }

    func test_apply_zoomWithTrajectory_atFirstSample_usesFirstPoint() {
        let base = baseLayout()
        // Samples kept inside the [0.25, 0.75] no-clamp range for a 2× zoom
        // on a 1920×1080 base — the recoveredCenter helper inverts assuming
        // no clamp.
        let kf = trajectoryZoomKeyframe(
            timelineStart: 0,
            duration: 2,
            trajectory: [
                ZoomTrajectorySample(t: 0, x: 0.3, y: 0.7),
                ZoomTrajectorySample(t: 1, x: 0.7, y: 0.3)
            ]
        )
        let result = EffectEvaluator.apply(keyframes: [kf], baseLayout: base, atTime: 0)
        let (cx, cy) = recoveredCenter(from: result, base: base)
        XCTAssertEqual(cx, 0.3, accuracy: 0.001)
        XCTAssertEqual(cy, 0.7, accuracy: 0.001)
    }

    func test_apply_zoomWithTrajectory_atLastSample_usesLastPoint() {
        let base = baseLayout()
        let kf = trajectoryZoomKeyframe(
            timelineStart: 0,
            duration: 2,
            trajectory: [
                ZoomTrajectorySample(t: 0, x: 0.3, y: 0.7),
                ZoomTrajectorySample(t: 1, x: 0.7, y: 0.3)
            ]
        )
        let result = EffectEvaluator.apply(keyframes: [kf], baseLayout: base, atTime: 1)
        let (cx, cy) = recoveredCenter(from: result, base: base)
        XCTAssertEqual(cx, 0.7, accuracy: 0.001)
        XCTAssertEqual(cy, 0.3, accuracy: 0.001)
    }

    func test_apply_zoomWithTrajectory_midSegment_twoSamplesFallBackToLinear() {
        let base = baseLayout()
        // With only 2 samples we lack the outer neighbours Catmull-Rom needs,
        // so the evaluator falls back to linear interpolation and the
        // midpoint is the algebraic average.
        let kf = trajectoryZoomKeyframe(
            timelineStart: 0,
            duration: 2,
            trajectory: [
                ZoomTrajectorySample(t: 0, x: 0.3, y: 0.7),
                ZoomTrajectorySample(t: 1, x: 0.7, y: 0.3)
            ]
        )
        let result = EffectEvaluator.apply(keyframes: [kf], baseLayout: base, atTime: 0.5)
        let (cx, cy) = recoveredCenter(from: result, base: base)
        XCTAssertEqual(cx, 0.5, accuracy: 0.001)
        XCTAssertEqual(cy, 0.5, accuracy: 0.001)
    }

    // MARK: - Temporal motion blur (dual UV transforms)

    private func transformDelta(_ layout: ResolvedLayout) -> Float {
        let d = layout.screenUVClose - layout.screenUVOpen
        return (d.x * d.x + d.y * d.y + d.z * d.z + d.w * d.w).squareRoot()
    }

    private let identity = ResolvedLayout.identityUVTransform

    func test_apply_zeroShutter_keepsIdentityUVTransforms() {
        let base = baseLayout()
        let kf = trajectoryZoomKeyframe(
            timelineStart: 0,
            duration: 2,
            trajectory: [
                ZoomTrajectorySample(t: 0, x: 0.30, y: 0.50),
                ZoomTrajectorySample(t: 1, x: 0.70, y: 0.50)
            ]
        )
        let result = EffectEvaluator.apply(keyframes: [kf], baseLayout: base, atTime: 0.5)
        XCTAssertEqual(result.screenUVOpen, identity)
        XCTAssertEqual(result.screenUVClose, identity)
    }

    func test_apply_panDuringHold_shutterTransformsSpanTheMotion() {
        let base = baseLayout()
        let kf = trajectoryZoomKeyframe(
            timelineStart: 0,
            duration: 2,
            trajectory: [
                ZoomTrajectorySample(t: 0, x: 0.30, y: 0.50),
                ZoomTrajectorySample(t: 1, x: 0.70, y: 0.50)
            ]
        )
        let result = EffectEvaluator.apply(
            keyframes: [kf], baseLayout: base, atTime: 0.5, shutterSeconds: 1.0 / 120.0
        )
        // The camera pans purely in x during the hold, so open and close
        // transforms must differ in their x offset and nowhere in y.
        XCTAssertGreaterThan(transformDelta(result), 1e-5,
                             "a panning camera must produce a shutter transform delta")
        XCTAssertNotEqual(result.screenUVOpen.z, result.screenUVClose.z,
                          "x offsets must differ across the shutter window")
        XCTAssertEqual(result.screenUVOpen.w, result.screenUVClose.w, accuracy: 1e-6,
                       "a pure-x pan must not produce a y delta")
        XCTAssertEqual(result.screenUVOpen.x, result.screenUVClose.x, accuracy: 1e-6,
                       "constant zoom during hold → no scale delta")
    }

    func test_apply_fasterPanProducesLargerShutterDelta() {
        let base = baseLayout()
        let slow = trajectoryZoomKeyframe(
            timelineStart: 0,
            duration: 2,
            trajectory: [
                ZoomTrajectorySample(t: 0, x: 0.40, y: 0.50),
                ZoomTrajectorySample(t: 1, x: 0.60, y: 0.50)
            ]
        )
        let fast = trajectoryZoomKeyframe(
            timelineStart: 0,
            duration: 2,
            trajectory: [
                ZoomTrajectorySample(t: 0, x: 0.30, y: 0.50),
                ZoomTrajectorySample(t: 1, x: 0.70, y: 0.50)
            ]
        )
        let shutter = 1.0 / 120.0
        let slowResult = EffectEvaluator.apply(
            keyframes: [slow], baseLayout: base, atTime: 0.5, shutterSeconds: shutter
        )
        let fastResult = EffectEvaluator.apply(
            keyframes: [fast], baseLayout: base, atTime: 0.5, shutterSeconds: shutter
        )
        XCTAssertGreaterThan(transformDelta(fastResult), transformDelta(slowResult),
                             "blur intensity must come from real camera velocity")
    }

    func test_apply_easeInScaleChange_producesScaleDelta() {
        // Mid ease-in the zoom factor itself is changing — the shutter
        // window spans two different scales, which is exactly the radial
        // blur a real camera records while zooming. Open/close transforms
        // must differ in their scale components.
        let base = baseLayout()
        let kf = EffectKeyframe(
            kind: .zoom,
            timelineRange: TimeRange(start: .seconds(0), duration: .seconds(2)),
            zoomFactor: 2.0,
            centerX: 0.5,
            centerY: 0.5,
            easeIn: .seconds(0.5),
            easeOut: .seconds(0.5)
        )
        let result = EffectEvaluator.apply(
            keyframes: [kf], baseLayout: base, atTime: 0.25, shutterSeconds: 1.0 / 60.0
        )
        XCTAssertNotEqual(result.screenUVOpen.x, result.screenUVClose.x,
                          "a changing zoom factor must produce a scale delta across the shutter")
    }

    func test_apply_zoomWithStationaryTrajectory_keepsScreenCrisp() {
        let base = baseLayout()
        let kf = trajectoryZoomKeyframe(
            timelineStart: 0,
            duration: 2,
            trajectory: [
                ZoomTrajectorySample(t: 0, x: 0.50, y: 0.50),
                ZoomTrajectorySample(t: 1, x: 0.50, y: 0.50)
            ]
        )
        let result = EffectEvaluator.apply(
            keyframes: [kf], baseLayout: base, atTime: 0.5, shutterSeconds: 1.0 / 120.0
        )
        XCTAssertEqual(result.screenZoomBlurSigmaPx, 0, accuracy: 1e-6,
                       "stationary held zooms must remain sharp")
        XCTAssertEqual(transformDelta(result), 0, accuracy: 1e-6,
                       "a still camera must collapse to identical shutter transforms")
    }

    func test_uvTransform_identityForSameRect_andCorrectMapping() {
        let rect = LayerRect(origin: CGPoint(x: 100, y: 50), size: CGSize(width: 800, height: 600))
        XCTAssertEqual(EffectEvaluator.uvTransform(from: rect, to: rect), identity)

        // Shifted rect: output pixel at rect's uv (0.5, 0.5) = (500, 350)px.
        // Under `other` (origin 140,50, same size) that pixel's uv is
        // ((500-140)/800, (350-50)/600) = (0.45, 0.5).
        let other = LayerRect(origin: CGPoint(x: 140, y: 50), size: CGSize(width: 800, height: 600))
        let t = EffectEvaluator.uvTransform(from: rect, to: other)
        let mappedX = 0.5 * t.x + t.z
        let mappedY = 0.5 * t.y + t.w
        XCTAssertEqual(mappedX, 0.45, accuracy: 1e-6)
        XCTAssertEqual(mappedY, 0.5, accuracy: 1e-6)
    }

    func test_apply_zoomWithTrajectory_catmullRomMidpoint_differsFromLinearMidpointWhenNeighborsDiffer() {
        let base = baseLayout()
        // Four samples chosen so the Catmull-Rom midpoint of the middle
        // segment is provably different from the linear midpoint. The two
        // bracketing y samples are flat at 0.50 but the outer neighbours
        // (0.30, 0.30) give the segment opposite-sign tangents at each
        // endpoint, producing a hump above 0.50 at the midpoint. Linear
        // interpolation would simply return 0.50. All samples stay inside
        // the no-clamp safe range [0.25, 0.75] for the 2× zoom.
        let kf = trajectoryZoomKeyframe(
            timelineStart: 0,
            duration: 4,
            trajectory: [
                ZoomTrajectorySample(t: 0.0, x: 0.30, y: 0.30),
                ZoomTrajectorySample(t: 1.0, x: 0.40, y: 0.50),
                ZoomTrajectorySample(t: 2.0, x: 0.60, y: 0.50),
                ZoomTrajectorySample(t: 3.0, x: 0.70, y: 0.30)
            ]
        )
        let result = EffectEvaluator.apply(keyframes: [kf], baseLayout: base, atTime: 1.5)
        let (cx, cy) = recoveredCenter(from: result, base: base)
        // x neighbours are symmetric around the bracketing pair → curve
        // still hits the algebraic midpoint.
        XCTAssertEqual(cx, 0.5, accuracy: 0.001)
        // y outer neighbours pull P1 and P2's tangents to +0.10 and -0.10.
        // Hermite form at u=0.5: 0.50 + 0.125·(+0.10) - (-0.125)·(-0.10)
        //                     = 0.50 + 0.0125 + 0.0125 = 0.525.
        XCTAssertEqual(cy, 0.525, accuracy: 0.001,
                       "Catmull-Rom produces a value different from the linear midpoint when outer neighbours differ")
    }

    func test_apply_zoomWithTrajectory_catmullRomMonotonic_staysWithinBracketingPair() {
        let base = baseLayout()
        // Monotone-increasing y in the inner pair; outer neighbours extend
        // the monotone trend modestly. Catmull-Rom should stay inside
        // [P1, P2] at the midpoint (no overshoot for "nice" data).
        let kf = trajectoryZoomKeyframe(
            timelineStart: 0,
            duration: 4,
            trajectory: [
                ZoomTrajectorySample(t: 0.0, x: 0.30, y: 0.30),
                ZoomTrajectorySample(t: 1.0, x: 0.40, y: 0.40),
                ZoomTrajectorySample(t: 2.0, x: 0.55, y: 0.55),
                ZoomTrajectorySample(t: 3.0, x: 0.70, y: 0.65)
            ]
        )
        let result = EffectEvaluator.apply(keyframes: [kf], baseLayout: base, atTime: 1.5)
        let (cx, cy) = recoveredCenter(from: result, base: base)
        XCTAssertGreaterThan(cx, 0.40)
        XCTAssertLessThan(cx, 0.55)
        XCTAssertGreaterThan(cy, 0.40)
        XCTAssertLessThan(cy, 0.55)
    }

    func test_apply_zoomWithTrajectory_catmullRom_continuousAcrossSampleBoundary() {
        let base = baseLayout()
        // Four samples; pick a sample boundary (t=2.0) and sample slightly
        // before and after. Catmull-Rom is C¹-continuous across interior
        // samples — the value should be near-identical at t-ε and t+ε, and
        // the implied left/right velocities should be similar.
        let kf = trajectoryZoomKeyframe(
            timelineStart: 0,
            duration: 4,
            trajectory: [
                ZoomTrajectorySample(t: 0.0, x: 0.30, y: 0.35),
                ZoomTrajectorySample(t: 1.0, x: 0.40, y: 0.55),
                ZoomTrajectorySample(t: 2.0, x: 0.55, y: 0.60),
                ZoomTrajectorySample(t: 3.0, x: 0.70, y: 0.50)
            ]
        )
        let eps = 1.0 / 60.0
        let preResult = EffectEvaluator.apply(keyframes: [kf], baseLayout: base, atTime: 2.0 - eps)
        let atResult = EffectEvaluator.apply(keyframes: [kf], baseLayout: base, atTime: 2.0)
        let postResult = EffectEvaluator.apply(keyframes: [kf], baseLayout: base, atTime: 2.0 + eps)
        let (preCX, preCY) = recoveredCenter(from: preResult, base: base)
        let (atCX, atCY) = recoveredCenter(from: atResult, base: base)
        let (postCX, postCY) = recoveredCenter(from: postResult, base: base)
        XCTAssertEqual(preCX, atCX, accuracy: 0.005, "position continuous through the boundary (x, left side)")
        XCTAssertEqual(postCX, atCX, accuracy: 0.005, "position continuous through the boundary (x, right side)")
        XCTAssertEqual(preCY, atCY, accuracy: 0.005, "position continuous through the boundary (y, left side)")
        XCTAssertEqual(postCY, atCY, accuracy: 0.005, "position continuous through the boundary (y, right side)")
        // Velocity continuity check: the difference (post - at) / eps should
        // be close to (at - pre) / eps. Catmull-Rom guarantees these are
        // exactly equal at the boundary in the limit; with finite eps we get
        // a small mismatch but it must be small relative to the velocity
        // itself.
        let leftVx = (atCX - preCX) / eps
        let rightVx = (postCX - atCX) / eps
        XCTAssertEqual(leftVx, rightVx, accuracy: 0.05,
                       "velocity continuous across the interior sample boundary")
    }

    func test_apply_zoomWithTrajectory_easeInReleaseDoesNotSnapPlacement() {
        let base = baseLayout()
        let kf = EffectKeyframe(
            kind: .zoom,
            timelineRange: TimeRange(start: .seconds(0), duration: .seconds(2)),
            zoomFactor: 2.0,
            easeIn: .seconds(0.55),
            easeOut: .seconds(0.55),
            trajectory: [
                ZoomTrajectorySample(t: 0.0, x: 0.30, y: 0.50),
                ZoomTrajectorySample(t: 0.55, x: 0.58, y: 0.50),
                ZoomTrajectorySample(t: 1.0, x: 0.62, y: 0.50),
                ZoomTrajectorySample(t: 2.0, x: 0.62, y: 0.50)
            ]
        )
        let atRelease = EffectEvaluator.apply(keyframes: [kf], baseLayout: base, atTime: 0.55)
        let nextFrame = EffectEvaluator.apply(keyframes: [kf], baseLayout: base, atTime: 0.55 + 1.0 / 60.0)
        let dx = abs(nextFrame.screen.origin.x - atRelease.screen.origin.x)
        XCTAssertLessThan(dx, 40,
                          "center handoff after ease-in should not snap the fully-zoomed frame into place")
    }

    func test_apply_zoomWithTrajectory_easeInTracksTheLiveCameraPath() {
        // The zoom-in must follow the camera path WHILE it ramps — not
        // freeze at the trigger point and snap to the live path afterwards.
        let base = baseLayout()
        let kf = EffectKeyframe(
            kind: .zoom,
            timelineRange: TimeRange(start: .seconds(0), duration: .seconds(2)),
            zoomFactor: 2.0,
            easeIn: .seconds(0.55),
            easeOut: .seconds(0.55),
            trajectory: [
                ZoomTrajectorySample(t: 0.0, x: 0.30, y: 0.50),
                ZoomTrajectorySample(t: 0.02, x: 0.58, y: 0.50),
                ZoomTrajectorySample(t: 0.30, x: 0.60, y: 0.50),
                ZoomTrajectorySample(t: 2.0, x: 0.60, y: 0.50)
            ]
        )
        let result = EffectEvaluator.apply(keyframes: [kf], baseLayout: base, atTime: 0.10)
        let (cx, _) = recoveredCenter(from: result, base: base)
        XCTAssertGreaterThan(cx, 0.52,
                             "mid-ease the centre must already be tracking the live path, not the stale frame-zero position")
    }

    func test_apply_zoomWithTrajectory_easeOutStartDoesNotSnapToFinalSample() {
        let base = baseLayout()
        let kf = EffectKeyframe(
            kind: .zoom,
            timelineRange: TimeRange(start: .seconds(0), duration: .seconds(2)),
            zoomFactor: 2.0,
            easeIn: .seconds(0.55),
            easeOut: .seconds(0.55),
            trajectory: [
                ZoomTrajectorySample(t: 0.0, x: 0.35, y: 0.50),
                ZoomTrajectorySample(t: 1.0, x: 0.42, y: 0.50),
                ZoomTrajectorySample(t: 1.45, x: 0.45, y: 0.50),
                ZoomTrajectorySample(t: 2.0, x: 0.70, y: 0.50)
            ]
        )
        let eps = 1.0 / 60.0
        let beforeEaseOut = EffectEvaluator.apply(keyframes: [kf], baseLayout: base, atTime: 1.45 - eps)
        let atEaseOut = EffectEvaluator.apply(keyframes: [kf], baseLayout: base, atTime: 1.45)
        let dx = abs(atEaseOut.screen.origin.x - beforeEaseOut.screen.origin.x)
        XCTAssertLessThan(dx, 40,
                          "ease-out should freeze at the current center, not jump to the trajectory's final sample")
    }

    func test_apply_zoomWithTrajectory_catmullRom_firstSegmentMirrorsBoundary() {
        let base = baseLayout()
        // First interior segment (between trajectory[0] and trajectory[1])
        // has no left neighbour; the evaluator mirrors trajectory[0] as the
        // outer neighbour so the curve still produces a finite result.
        // Cross-checked: with the mirror trick, at the sample boundary t=0
        // the position equals trajectory[0] exactly.
        let kf = trajectoryZoomKeyframe(
            timelineStart: 0,
            duration: 4,
            trajectory: [
                ZoomTrajectorySample(t: 0.0, x: 0.30, y: 0.70),
                ZoomTrajectorySample(t: 1.0, x: 0.50, y: 0.50),
                ZoomTrajectorySample(t: 2.0, x: 0.70, y: 0.30)
            ]
        )
        // localT just after the first sample; verify the position is bounded
        // between trajectory[0] and trajectory[1] (no extrapolation
        // overshoot from a mishandled boundary).
        let result = EffectEvaluator.apply(keyframes: [kf], baseLayout: base, atTime: 0.1)
        let (cx, cy) = recoveredCenter(from: result, base: base)
        XCTAssertGreaterThanOrEqual(cx, 0.30 - 0.01)
        XCTAssertLessThanOrEqual(cx, 0.50 + 0.01)
        XCTAssertGreaterThanOrEqual(cy, 0.50 - 0.01)
        XCTAssertLessThanOrEqual(cy, 0.70 + 0.01)
    }

    func test_apply_zoomWithTrajectory_outOfRangeBefore_clampsToFirst() {
        let base = baseLayout()
        // Timeline range starts at 5s. Sample times are keyframe-local
        // (t=0 at 5s, t=1 at 6s).
        let kf = trajectoryZoomKeyframe(
            timelineStart: 5,
            duration: 2,
            trajectory: [
                ZoomTrajectorySample(t: 0.5, x: 0.3, y: 0.4),
                ZoomTrajectorySample(t: 1.0, x: 0.7, y: 0.6)
            ]
        )
        // Composition time = 5.0 → localT = 0 < trajectory.first.t = 0.5;
        // should clamp to the first sample.
        let result = EffectEvaluator.apply(keyframes: [kf], baseLayout: base, atTime: 5.0)
        let (cx, cy) = recoveredCenter(from: result, base: base)
        XCTAssertEqual(cx, 0.3, accuracy: 0.001)
        XCTAssertEqual(cy, 0.4, accuracy: 0.001)
    }

    func test_apply_zoomWithTrajectory_outOfRangeAfter_clampsToLast() {
        let base = baseLayout()
        let kf = trajectoryZoomKeyframe(
            timelineStart: 0,
            duration: 2,
            trajectory: [
                ZoomTrajectorySample(t: 0, x: 0.3, y: 0.4),
                ZoomTrajectorySample(t: 0.4, x: 0.7, y: 0.6)
            ]
        )
        // Composition time 1.5s, localT = 1.5 > last sample t (0.4) but
        // still inside the keyframe's 2s range. Should clamp to last.
        let result = EffectEvaluator.apply(keyframes: [kf], baseLayout: base, atTime: 1.5)
        let (cx, cy) = recoveredCenter(from: result, base: base)
        XCTAssertEqual(cx, 0.7, accuracy: 0.001)
        XCTAssertEqual(cy, 0.6, accuracy: 0.001)
    }

    func test_apply_zoomWithNilTrajectory_usesStaticCenter() {
        let base = baseLayout()
        let kf = trajectoryZoomKeyframe(
            timelineStart: 0,
            duration: 2,
            trajectory: nil
        )
        let result = EffectEvaluator.apply(keyframes: [kf], baseLayout: base, atTime: 1)
        let (cx, cy) = recoveredCenter(from: result, base: base)
        XCTAssertEqual(cx, 0.5, accuracy: 0.001)
        XCTAssertEqual(cy, 0.5, accuracy: 0.001)
    }

    func test_apply_zoomWithEmptyTrajectory_usesStaticCenter() {
        let base = baseLayout()
        let kf = trajectoryZoomKeyframe(
            timelineStart: 0,
            duration: 2,
            trajectory: []
        )
        let result = EffectEvaluator.apply(keyframes: [kf], baseLayout: base, atTime: 1)
        let (cx, cy) = recoveredCenter(from: result, base: base)
        XCTAssertEqual(cx, 0.5, accuracy: 0.001)
        XCTAssertEqual(cy, 0.5, accuracy: 0.001)
    }

    func test_apply_zoomWithSingleSampleTrajectory_usesThatSample() {
        let base = baseLayout()
        let kf = trajectoryZoomKeyframe(
            timelineStart: 0,
            duration: 2,
            trajectory: [ZoomTrajectorySample(t: 0.5, x: 0.25, y: 0.75)]
        )
        // Any composition time clamps to the one sample.
        let result = EffectEvaluator.apply(keyframes: [kf], baseLayout: base, atTime: 1.0)
        let (cx, cy) = recoveredCenter(from: result, base: base)
        XCTAssertEqual(cx, 0.25, accuracy: 0.001)
        XCTAssertEqual(cy, 0.75, accuracy: 0.001)
    }

    // MARK: - Talking head

    func test_apply_talkingHead_outsideRange_leavesLayoutUnchanged() {
        let base = baseLayout()
        let kf = EffectKeyframe(
            kind: .talkingHeadSwap,
            timelineRange: TimeRange(start: .seconds(2), duration: .seconds(2))
        )
        let result = EffectEvaluator.apply(keyframes: [kf], baseLayout: base, atTime: 0.5)
        XCTAssertEqual(result, base)
        XCTAssertEqual(result.webcamOpacity, 1.0, accuracy: 0.0001)
    }

    func test_apply_talkingHeadAtFullStrength_webcamFillsScreenAtFullOpacity() {
        let base = baseLayout()
        let kf = EffectKeyframe(
            kind: .talkingHeadSwap,
            timelineRange: TimeRange(start: .seconds(0), duration: .seconds(2)),
            easeIn: .seconds(0),
            easeOut: .seconds(0)
        )
        let result = EffectEvaluator.apply(keyframes: [kf], baseLayout: base, atTime: 1)
        XCTAssertEqual(result.webcam, base.screen,
                       "webcam reparented onto the screen rect for full swap")
        XCTAssertEqual(result.webcamOpacity, 1.0, accuracy: 0.0001)
        XCTAssertEqual(result.screen, base.screen, "screen rect unchanged underneath")
    }

    func test_apply_talkingHeadAtHalfStrength_webcamCoversScreenAtHalfOpacity() {
        let base = baseLayout()
        // Use a 2s range with 1s ease-in + 1s ease-out so easeIn ends at
        // exactly t = 1s → strength = 1, the hold portion is zero-length,
        // and ease-out begins immediately. The mid-easeIn sample (t = 0.5)
        // sits in the smoothstep curve where strength ≠ 0.5 exactly, so
        // sample at t = 1 instead for a deterministic strength = 1.0 and
        // at t = 1.5 for a deterministic strength = 0.5 (mid-easeOut).
        let kf = EffectKeyframe(
            kind: .talkingHeadSwap,
            timelineRange: TimeRange(start: .seconds(0), duration: .seconds(2)),
            easeIn: .seconds(1),
            easeOut: .seconds(1)
        )
        let result = EffectEvaluator.apply(keyframes: [kf], baseLayout: base, atTime: 1.5)
        XCTAssertEqual(result.webcam, base.screen)
        XCTAssertEqual(Double(result.webcamOpacity), 0.5, accuracy: 0.0001)
    }

    func test_apply_talkingHeadLowStrength_crossfadesAtScreenRect_notInPipSlot() {
        let base = baseLayout()
        let kf = EffectKeyframe(
            kind: .talkingHeadSwap,
            timelineRange: TimeRange(start: .seconds(0), duration: .seconds(2)),
            easeIn: .seconds(1),
            easeOut: .seconds(1)
        )
        // Tiny strength: the PiP slot is gone (webcam moved to screen rect)
        // and the cam crossfades in at low opacity. This is the cost of the
        // continuous-strength model — there's a small "pop" at the moment
        // strength leaves 0, but the rest of the ramp is smooth.
        let result = EffectEvaluator.apply(keyframes: [kf], baseLayout: base, atTime: 0.05)
        XCTAssertEqual(result.webcam, base.screen)
        XCTAssertLessThan(Double(result.webcamOpacity), 0.5)
        XCTAssertGreaterThan(Double(result.webcamOpacity), 0)
    }

    func test_apply_talkingHead_noWebcam_isNoOp() {
        var base = baseLayout()
        base.webcam = nil
        let kf = EffectKeyframe(
            kind: .talkingHeadSwap,
            timelineRange: TimeRange(start: .seconds(0), duration: .seconds(2)),
            easeIn: .seconds(0),
            easeOut: .seconds(0)
        )
        let result = EffectEvaluator.apply(keyframes: [kf], baseLayout: base, atTime: 1)
        XCTAssertNil(result.webcam)
        XCTAssertEqual(result.webcamOpacity, 1.0, accuracy: 0.0001)
    }

    // MARK: - Zoom non-overlap backstop (slice #11.f L4)

    func test_apply_zoom_highestStrengthWins_whenTwoOverlap() {
        let base = baseLayout()
        // Two overlapping zoom keyframes; both active at t=4. The earlier one
        // is fully held (strength = 1) at t=4; the later one is mid-ease-in.
        // Expected: render exactly what the strength=1 keyframe produces
        // alone — not the compounded 2.56× zoom from cumulative apply.
        let earlier = EffectKeyframe(
            kind: .zoom,
            timelineRange: TimeRange(start: .seconds(2), duration: .seconds(4)),
            zoomFactor: 1.6,
            centerX: 0.5,
            centerY: 0.5,
            easeIn: .seconds(0.5),
            easeOut: .seconds(0.5)
        )
        let later = EffectKeyframe(
            kind: .zoom,
            timelineRange: TimeRange(start: .seconds(3.5), duration: .seconds(3)),
            zoomFactor: 1.6,
            centerX: 0.5,
            centerY: 0.5,
            easeIn: .seconds(1.0),
            easeOut: .seconds(0.5)
        )
        let withBoth = EffectEvaluator.apply(
            keyframes: [earlier, later], baseLayout: base, atTime: 4.0
        )
        let withEarlierAlone = EffectEvaluator.apply(
            keyframes: [earlier], baseLayout: base, atTime: 4.0
        )
        XCTAssertEqual(withBoth.screen, withEarlierAlone.screen,
                       "highest-strength zoom must apply alone, not compound")
    }

    func test_apply_zoom_tiebreak_picksLatestStart() {
        let base = baseLayout()
        // Two zooms with identical start/duration/ease windows so their
        // strength curves are equal. Tie-break rule: latest `start` wins.
        // Place them at different centres so we can tell which one applied.
        let earlier = EffectKeyframe(
            kind: .zoom,
            timelineRange: TimeRange(start: .seconds(2), duration: .seconds(3)),
            zoomFactor: 2.0,
            centerX: 0.2, centerY: 0.2,
            easeIn: .seconds(0.5),
            easeOut: .seconds(0.5)
        )
        let later = EffectKeyframe(
            kind: .zoom,
            timelineRange: TimeRange(start: .seconds(3), duration: .seconds(3)),
            zoomFactor: 2.0,
            centerX: 0.8, centerY: 0.8,
            easeIn: .seconds(0.5),
            easeOut: .seconds(0.5)
        )
        // At t=4: both keyframes are in hold (strength=1). Tie-break picks
        // the later one — so the zoom anchors at (0.8, 0.8).
        let result = EffectEvaluator.apply(
            keyframes: [earlier, later], baseLayout: base, atTime: 4.0
        )
        let withLaterAlone = EffectEvaluator.apply(
            keyframes: [later], baseLayout: base, atTime: 4.0
        )
        XCTAssertEqual(result.screen, withLaterAlone.screen,
                       "tie-break by latest start — later keyframe wins")
    }

    func test_apply_zoom_disjointKeyframes_eachApplyAtOwnTime() {
        let base = baseLayout()
        // Two non-overlapping zoom keyframes. Each one should apply normally
        // at its own time; this is the negative case for the winner rule —
        // it must not pessimise the common case.
        let first = EffectKeyframe(
            kind: .zoom,
            timelineRange: TimeRange(start: .seconds(1), duration: .seconds(2)),
            zoomFactor: 1.6,
            centerX: 0.5, centerY: 0.5,
            easeIn: .seconds(0.2),
            easeOut: .seconds(0.2)
        )
        let second = EffectKeyframe(
            kind: .zoom,
            timelineRange: TimeRange(start: .seconds(4), duration: .seconds(2)),
            zoomFactor: 1.6,
            centerX: 0.5, centerY: 0.5,
            easeIn: .seconds(0.2),
            easeOut: .seconds(0.2)
        )
        // At t=2, only `first` is active → zoom applies.
        let atFirstTime = EffectEvaluator.apply(
            keyframes: [first, second], baseLayout: base, atTime: 2.0
        )
        XCTAssertNotEqual(atFirstTime.screen, base.screen,
                          "first keyframe must zoom at its own time")
        // At t=5, only `second` is active.
        let atSecondTime = EffectEvaluator.apply(
            keyframes: [first, second], baseLayout: base, atTime: 5.0
        )
        XCTAssertNotEqual(atSecondTime.screen, base.screen,
                          "second keyframe must zoom at its own time")
        // Between them at t=3.5, neither is active → unchanged.
        let between = EffectEvaluator.apply(
            keyframes: [first, second], baseLayout: base, atTime: 3.5
        )
        XCTAssertEqual(between.screen, base.screen,
                       "no active keyframes → base layout")
    }

    func test_apply_talkingHeadStillStacks_whenZoomDoesNot() {
        let base = baseLayout()
        // Two overlapping talking-head keyframes — these affect webcam
        // opacity and the new zoom rule must not change their behaviour
        // (they're stacked via the second loop, opacity composed by the
        // last one to apply at full strength = 1.0).
        let first = EffectKeyframe(
            kind: .talkingHeadSwap,
            timelineRange: TimeRange(start: .seconds(1), duration: .seconds(3)),
            easeIn: .seconds(0),
            easeOut: .seconds(0)
        )
        let second = EffectKeyframe(
            kind: .talkingHeadSwap,
            timelineRange: TimeRange(start: .seconds(2), duration: .seconds(3)),
            easeIn: .seconds(0),
            easeOut: .seconds(0)
        )
        let result = EffectEvaluator.apply(
            keyframes: [first, second], baseLayout: base, atTime: 2.5
        )
        // Webcam reparented onto screen rect, full opacity from both.
        XCTAssertEqual(result.webcam, base.screen)
        XCTAssertEqual(Float(result.webcamOpacity), 1.0, accuracy: 0.0001)
    }
}
