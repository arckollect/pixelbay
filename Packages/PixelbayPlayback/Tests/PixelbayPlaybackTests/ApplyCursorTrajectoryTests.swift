import PixelbayCore
@testable import PixelbayPlayback
import XCTest

final class ApplyCursorTrajectoryTests: XCTestCase {
    // The pinned-skip contract is load-bearing for the gesture-static-anchor
    // fix. PreviewComposition.applyCursorTrajectory runs at every composition
    // build (including playback rebuilds) and would otherwise re-window the
    // master cursor trajectory onto every zoom keyframe — silently re-
    // enabling cursor-follow on keyframes the editor explicitly marked as
    // region-locked. These tests pin the contract so any future refactor
    // that loses the `anchorMode == .pinned` short-circuit fails fast.

    private func makeZoom(
        start: Double = 1.0,
        duration: Double = 1.4,
        anchorMode: ZoomAnchorMode = .followCursor,
        trajectory: [ZoomTrajectorySample]? = nil,
        followLeadSeconds: Double = 0
    ) -> EffectKeyframe {
        EffectKeyframe(
            kind: .zoom,
            timelineRange: TimeRange(
                start: .seconds(start),
                duration: .seconds(duration)
            ),
            trajectory: trajectory,
            anchorMode: anchorMode,
            followLeadSeconds: followLeadSeconds
        )
    }

    private func masterTrajectory() -> [MouseTrajectorySample] {
        (0..<30).map {
            MouseTrajectorySample(
                timelineTime: Double($0) * 0.1,
                centerX: 0.5 + 0.1 * Double($0).truncatingRemainder(dividingBy: 2),
                centerY: 0.5
            )
        }
    }

    private func reversalTrajectory() -> [MouseTrajectorySample] {
        let dt = 1.0 / 60.0
        var samples: [MouseTrajectorySample] = []
        for i in 0...30 {
            samples.append(MouseTrajectorySample(
                timelineTime: 1.0 + Double(i) * dt,
                centerX: 0.30 + 0.40 * Double(i) / 30.0,
                centerY: 0.5
            ))
        }
        for i in 1...30 {
            samples.append(MouseTrajectorySample(
                timelineTime: 1.0 + Double(30 + i) * dt,
                centerX: 0.70 - 0.35 * Double(i) / 30.0,
                centerY: 0.5
            ))
        }
        return samples
    }

    func test_pinnedKeyframe_trajectoryStaysNil_evenWithMasterAvailable() {
        let pinned = makeZoom(anchorMode: .pinned, trajectory: nil)
        let result = PreviewCompositionBuilder.applyCursorTrajectory(
            to: [pinned],
            cursorTrajectory: masterTrajectory()
        )
        XCTAssertEqual(result.count, 1)
        XCTAssertNil(result[0].trajectory,
                     "pinned keyframes must not have trajectory backfilled at composition build time")
        XCTAssertEqual(result[0].anchorMode, .pinned)
    }

    func test_pinnedKeyframe_preservesExistingNonEmptyTrajectory_unchanged() {
        // Edge case: a pinned keyframe that *also* happens to carry a
        // trajectory (e.g., authored by some future code path) should still
        // pass through untouched — pinning beats any trajectory present.
        let existing: [ZoomTrajectorySample] = [
            ZoomTrajectorySample(t: 0.0, x: 0.3, y: 0.4),
            ZoomTrajectorySample(t: 0.5, x: 0.7, y: 0.4)
        ]
        let pinned = makeZoom(anchorMode: .pinned, trajectory: existing)
        let result = PreviewCompositionBuilder.applyCursorTrajectory(
            to: [pinned],
            cursorTrajectory: masterTrajectory()
        )
        XCTAssertEqual(result[0].trajectory, existing,
                       "pinned keyframes pass through with their existing trajectory intact")
    }

    func test_followCursorKeyframe_getsTrajectoryFilled() {
        // The original behaviour: an unpinned keyframe with no trajectory
        // gets one filled in from the master. Regression guard against
        // accidentally widening the pinned-skip to all manual keyframes.
        let unpinned = makeZoom(anchorMode: .followCursor, trajectory: nil)
        let result = PreviewCompositionBuilder.applyCursorTrajectory(
            to: [unpinned],
            cursorTrajectory: masterTrajectory()
        )
        XCTAssertNotNil(result[0].trajectory,
                        "unpinned keyframes must still have trajectory filled in by the composition pass")
        XCTAssertFalse(result[0].trajectory!.isEmpty)
    }

    func test_centerCursorKeyframe_usesWindowedCursorPathDirectly() {
        let input = masterTrajectory()
        let centered = makeZoom(anchorMode: .centerCursor, trajectory: nil)
        let result = PreviewCompositionBuilder.applyCursorTrajectory(
            to: [centered],
            cursorTrajectory: input
        )
        let trajectory = result[0].trajectory ?? []
        XCTAssertFalse(trajectory.isEmpty)
        XCTAssertEqual(trajectory[0].x, input[10].centerX, accuracy: 1e-9)
        XCTAssertEqual(trajectory[0].y, input[10].centerY, accuracy: 1e-9)
    }

    func test_emptyMasterTrajectory_passesAllKeyframesThrough() {
        let pinned = makeZoom(anchorMode: .pinned, trajectory: nil)
        let unpinned = makeZoom(anchorMode: .followCursor, trajectory: nil)
        let result = PreviewCompositionBuilder.applyCursorTrajectory(
            to: [pinned, unpinned],
            cursorTrajectory: []
        )
        XCTAssertNil(result[0].trajectory)
        XCTAssertNil(result[1].trajectory)
    }

    // Follow-cursor zooms route only the camera anchor through an elastic
    // slack spring. The visible cursor stays on the raw capture path, while
    // the zoom frame ignores tiny pointer wiggles inside the slack radius.
    func test_applyCursorTrajectory_followCursor_smallMotionInsideSlackKeepsAnchorStill() {
        // Cursor wanders gently within ±0.04 of the start position. The
        // default slack is much wider than that at zoom 1.5, so this
        // should not make the camera chase every small jitter.
        let zoomFactor = 1.5
        let deadHalf = TuningSettings.default.deadzoneFraction / 2.0 / zoomFactor
        let input: [MouseTrajectorySample] = (0...20).map { i in
            MouseTrajectorySample(
                timelineTime: 1.0 + 0.05 * Double(i),
                centerX: 0.50 + 0.04 * sin(Double(i) * 0.5),
                centerY: 0.50 + 0.03 * sin(Double(i) * 0.7)
            )
        }
        let unpinned = makeZoom(start: 1.0, duration: 1.5, anchorMode: .followCursor)
        let result = PreviewCompositionBuilder.applyCursorTrajectory(
            to: [unpinned],
            cursorTrajectory: input
        )
        let trajectory = result[0].trajectory ?? []
        XCTAssertEqual(trajectory.count, input.count,
                       "all input samples lie inside the keyframe range — none should be dropped")
        let initialX = trajectory[0].x
        let initialY = trajectory[0].y
        for (cursorSample, anchor) in zip(input, trajectory) {
            XCTAssertLessThanOrEqual(abs(cursorSample.centerX - initialX), deadHalf + 1e-9)
            XCTAssertLessThanOrEqual(abs(cursorSample.centerY - initialY), deadHalf + 1e-9)
            XCTAssertEqual(anchor.x, initialX, accuracy: 1e-9)
            XCTAssertEqual(anchor.y, initialY, accuracy: 1e-9)
        }
    }

    // Bounded-float contract: a sustained move makes the anchor track the
    // cursor with visible-frame bounded lag. Confirms the
    // windowed slice IS being piped through anchorFollow, not stored raw.
    func test_applyCursorTrajectory_followCursor_anchorTracksWithBoundedLagOnSustainedMotion() {
        // Linear sweep across 0.4 norm-units over 2.0s. The follow camera
        // trails the cursor, but remains inside the visible zoomed viewport.
        let zoomFactor = 1.5
        let visibleHalf = 0.48 / zoomFactor
        let input: [MouseTrajectorySample] = (0...40).map { i in
            MouseTrajectorySample(
                timelineTime: 1.0 + 0.05 * Double(i),
                centerX: 0.20 + 0.01 * Double(i),
                centerY: 0.50
            )
        }
        let unpinned = makeZoom(start: 1.0, duration: 2.0, anchorMode: .followCursor)
        let result = PreviewCompositionBuilder.applyCursorTrajectory(
            to: [unpinned],
            cursorTrajectory: input
        )
        let trajectory = result[0].trajectory ?? []
        XCTAssertEqual(trajectory.count, input.count)
        let finalLag = input.last!.centerX - trajectory.last!.x
        XCTAssertGreaterThan(finalLag, 0.0,
                             "anchor must trail the cursor after a sustained move")
        XCTAssertLessThanOrEqual(finalLag, visibleHalf + 1e-9,
                                 "anchor lag must keep the cursor visible")
    }

    func test_applyCursorTrajectory_fastSweep_allowsReadableCameraTrail() {
        let zoomFactor = 1.5
        let oldTightSafeHalf = 0.30 / 2.0 / zoomFactor
        let visibleHalf = 0.48 / zoomFactor
        let input: [MouseTrajectorySample] = (0...12).map { i in
            MouseTrajectorySample(
                timelineTime: 1.0 + 0.025 * Double(i),
                centerX: 0.20 + 0.50 * Double(i) / 12.0,
                centerY: 0.50
            )
        }
        let unpinned = makeZoom(start: 1.0, duration: 0.3, anchorMode: .followCursor)
        let result = PreviewCompositionBuilder.applyCursorTrajectory(
            to: [unpinned],
            cursorTrajectory: input
        )
        let trajectory = result[0].trajectory ?? []
        XCTAssertEqual(trajectory.count, input.count)
        let maxLag = zip(input, trajectory).map { cursor, anchor in
            abs(cursor.centerX - anchor.x)
        }.max() ?? 0
        XCTAssertGreaterThan(maxLag, oldTightSafeHalf,
                             "fast sweeps should be allowed to trail beyond the old tight follow window")
        XCTAssertLessThanOrEqual(maxLag, visibleHalf + 1e-9,
                                 "fast sweeps must keep the cursor visible")
    }

    func test_applyCursorTrajectory_tuningSpeedLimitsCameraMovement() {
        let tuning = TuningSettings(maxPanSpeed: 0.45)
        let input: [MouseTrajectorySample] = (0...12).map { i in
            MouseTrajectorySample(
                timelineTime: 1.0 + 0.025 * Double(i),
                centerX: 0.20 + 0.30 * Double(i) / 12.0,
                centerY: 0.50
            )
        }
        let unpinned = makeZoom(start: 1.0, duration: 0.3, anchorMode: .followCursor)
        let result = PreviewCompositionBuilder.applyCursorTrajectory(
            to: [unpinned],
            cursorTrajectory: input,
            tuning: tuning
        )
        let trajectory = result[0].trajectory ?? []
        for i in 1..<trajectory.count {
            let dt = trajectory[i].t - trajectory[i - 1].t
            let dx = trajectory[i].x - trajectory[i - 1].x
            let dy = trajectory[i].y - trajectory[i - 1].y
            let distance = (dx * dx + dy * dy).squareRoot()
            XCTAssertLessThanOrEqual(
                distance,
                tuning.maxPanSpeed * dt + 1e-9,
                "tuning.maxPanSpeed must cap the camera's pan speed"
            )
        }
    }

    func test_applyCursorTrajectory_leavesKeyframeExtrasUntouched() {
        // The retired ZoomFollowStyle resolver used to stamp resolved
        // values onto every keyframe at composition build, silently
        // clobbering user edits. Tuning now flows straight into the solver
        // — the keyframe's stored extras must come back byte-identical.
        var unpinned = makeZoom(start: 1.0, duration: 1.2, anchorMode: .followCursor)
        // Stale pre-v6 keys riding along in extras must survive untouched.
        unpinned.extras["zoomFollowLookaheadSeconds"] = .double(0.20)
        unpinned.extras["zoomFollowTauRelaxed"] = .double(0.12)
        let extrasBefore = unpinned.extras

        let result = PreviewCompositionBuilder.applyCursorTrajectory(
            to: [unpinned],
            cursorTrajectory: masterTrajectory(),
            tuning: TuningSettings(cameraTau: 0.6, settle: 0.9, deadzoneFraction: 0.1)
        )

        XCTAssertEqual(result[0].extras, extrasBefore,
                       "applyCursorTrajectory must not stamp tuning onto keyframes")
        XCTAssertNotNil(result[0].trajectory, "trajectory should still be re-sliced and solved")
    }

    func test_applyCursorTrajectory_highSettleCarriesMoreMomentumPastALanding() {
        // Sweep right for 0.5 s, then hold for 1.5 s. A critically damped
        // camera (settle = 0) approaches the landing point without passing
        // it; an underdamped one (settle = 1) keeps momentum and drifts
        // further toward/past the target before easing back — its furthest
        // point must exceed the critically damped camera's.
        let dt = 1.0 / 60.0
        var input: [MouseTrajectorySample] = []
        for i in 0...30 {
            input.append(MouseTrajectorySample(
                timelineTime: 1.0 + Double(i) * dt,
                centerX: 0.25 + 0.40 * Double(i) / 30.0,
                centerY: 0.5
            ))
        }
        for i in 1...90 {
            input.append(MouseTrajectorySample(
                timelineTime: 1.0 + Double(30 + i) * dt,
                centerX: 0.65,
                centerY: 0.5
            ))
        }
        let zoom = makeZoom(start: 1.0, duration: 2.0, anchorMode: .followCursor)
        let lowSettle = PreviewCompositionBuilder.applyCursorTrajectory(
            to: [zoom],
            cursorTrajectory: input,
            tuning: TuningSettings(settle: 0.0)
        )[0].trajectory ?? []
        let highSettle = PreviewCompositionBuilder.applyCursorTrajectory(
            to: [zoom],
            cursorTrajectory: input,
            tuning: TuningSettings(settle: 1.0)
        )[0].trajectory ?? []

        let lowMaxX = lowSettle.map(\.x).max() ?? 0
        let highMaxX = highSettle.map(\.x).max() ?? 0
        XCTAssertGreaterThan(highMaxX, lowMaxX + 0.001,
                             "higher settle should carry the camera further on landing (elastic drift-past)")
    }

    func test_applyCursorTrajectory_lowCameraTauCatchesUpFasterThanHigh() {
        let input: [MouseTrajectorySample] = (0...60).map { i in
            MouseTrajectorySample(
                timelineTime: 1.0 + 2.0 * Double(i) / 60.0,
                centerX: 0.20 + 0.55 * Double(i) / 60.0,
                centerY: 0.50
            )
        }
        let zoom = makeZoom(start: 1.0, duration: 2.0, anchorMode: .followCursor)
        let heavy = PreviewCompositionBuilder.applyCursorTrajectory(
            to: [zoom],
            cursorTrajectory: input,
            tuning: TuningSettings(cameraTau: 0.80)
        )[0].trajectory ?? []
        let light = PreviewCompositionBuilder.applyCursorTrajectory(
            to: [zoom],
            cursorTrajectory: input,
            tuning: TuningSettings(cameraTau: 0.10)
        )[0].trajectory ?? []

        let heavyFinalLag = abs(input.last!.centerX - heavy.last!.x)
        let lightFinalLag = abs(input.last!.centerX - light.last!.x)
        XCTAssertLessThan(lightFinalLag, heavyFinalLag,
                          "a lighter cameraTau should track the cursor more tightly")
    }

    func test_blendByZoomStrength_rawOutsideZooms_smoothedInsideHold() {
        let raw: [MouseTrajectorySample] = (0...40).map { i in
            MouseTrajectorySample(timelineTime: 0.1 * Double(i), centerX: 0.2, centerY: 0.5)
        }
        let smoothed: [MouseTrajectorySample] = raw.map {
            MouseTrajectorySample(timelineTime: $0.timelineTime, centerX: 0.8, centerY: 0.5)
        }
        let zoom = makeZoom(start: 1.0, duration: 2.0, anchorMode: .followCursor)

        let blended = PreviewCompositionBuilder.blendByZoomStrength(
            raw: raw,
            smoothed: smoothed,
            effects: [zoom]
        )

        // t = 0.5 — outside the zoom: honest raw path.
        XCTAssertEqual(blended[5].centerX, 0.2, accuracy: 1e-9)
        // t = 2.0 — inside the hold (strength 1): fully stylized.
        XCTAssertEqual(blended[20].centerX, 0.8, accuracy: 1e-9)
        // t = 1.2 — mid ease-in: partially blended, strictly between.
        XCTAssertGreaterThan(blended[12].centerX, 0.2)
        XCTAssertLessThan(blended[12].centerX, 0.8)
        // t = 3.5 — after the zoom: raw again.
        XCTAssertEqual(blended[35].centerX, 0.2, accuracy: 1e-9)
    }

    // followLeadSeconds shifts the trajectory's first sample forward in
    // time. With leadSeconds = 0.15 the windowed slice starts at
    // timelineRange.start + 0.15, so trajectory[0].t == 0.15. The
    // EffectEvaluator.zoomCenter first-sample clamp then holds that
    // "predicted-future" anchor for localT ∈ [0, 0.15] — exactly what
    // gesture zooms need so the ramp-in points at where the cursor lands
    // post-shake, not at the wiggle center.
    func test_followLeadSeconds_shiftsTrajectoryStartForwardInTime() {
        let input: [MouseTrajectorySample] = (0...20).map { i in
            MouseTrajectorySample(
                timelineTime: 1.0 + 0.05 * Double(i),
                centerX: 0.20 + 0.03 * Double(i),
                centerY: 0.50
            )
        }
        let leadSeconds = 0.15
        let withLead = makeZoom(
            start: 1.0,
            duration: 1.5,
            anchorMode: .followCursor,
            followLeadSeconds: leadSeconds
        )
        let result = PreviewCompositionBuilder.applyCursorTrajectory(
            to: [withLead],
            cursorTrajectory: input
        )
        let trajectory = result[0].trajectory ?? []
        XCTAssertFalse(trajectory.isEmpty)
        XCTAssertGreaterThanOrEqual(trajectory[0].t, leadSeconds - 1e-9,
                                    "trajectory's first sample must land at or after the lookahead offset")
        // Cross-check: the first sample's x equals the damped master's x
        // at timelineRange.start + leadSeconds (the predicted-future anchor
        // point). Find the master sample at that absolute time.
        let leadAbsoluteT = 1.0 + leadSeconds
        let masterAtLead = input.first { $0.timelineTime >= leadAbsoluteT }!
        XCTAssertEqual(trajectory[0].x, masterAtLead.centerX, accuracy: 1e-9,
                       "trajectory[0] must originate from the master sample at start + leadSeconds")
    }
}
