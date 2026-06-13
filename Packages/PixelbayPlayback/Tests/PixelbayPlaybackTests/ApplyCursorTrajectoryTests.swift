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

    // Follow-cursor zooms route the camera anchor through the reference
    // adaptive follow layer. Small motion is damped, but there is no hard
    // deadzone: the camera naturally converges instead of freezing.
    func test_applyCursorTrajectory_followCursor_smallMotionIsDampedButNotFrozen() {
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
        XCTAssertEqual(trajectory[0].x, input[0].centerX, accuracy: 1e-9)
        XCTAssertEqual(trajectory[0].y, input[0].centerY, accuracy: 1e-9)
        XCTAssertNotEqual(trajectory.last!.x, trajectory[0].x)
        let rawPeakTravel = input.map { hypot($0.centerX - input[0].centerX, $0.centerY - input[0].centerY) }.max() ?? 0
        let followedPeakTravel = trajectory.map { hypot($0.x - trajectory[0].x, $0.y - trajectory[0].y) }.max() ?? 0
        XCTAssertLessThan(followedPeakTravel, rawPeakTravel)
    }

    func test_applyCursorTrajectory_followCursor_anchorTrailsSustainedMotion() {
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
        XCTAssertLessThan(finalLag, input.last!.centerX - input.first!.centerX,
                          "anchor should still make meaningful progress toward the cursor")
    }

    func test_applyCursorTrajectory_fastSweep_allowsReadableCameraTrail() {
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
        XCTAssertGreaterThan(maxLag, 0.05,
                             "fast sweeps should be visibly damped by adaptive follow")
        XCTAssertLessThan(maxLag, 0.50,
                          "the anchor should still move toward the cursor during a fast sweep")
    }

    func test_applyCursorTrajectory_usesReferenceFollowParamsInsteadOfProjectTuning() {
        let input: [MouseTrajectorySample] = (0...12).map { i in
            MouseTrajectorySample(
                timelineTime: 1.0 + 0.025 * Double(i),
                centerX: 0.20 + 0.30 * Double(i) / 12.0,
                centerY: 0.50
            )
        }
        let unpinned = makeZoom(start: 1.0, duration: 0.3, anchorMode: .followCursor)
        let defaultResult = PreviewCompositionBuilder.applyCursorTrajectory(
            to: [unpinned],
            cursorTrajectory: input
        )[0].trajectory ?? []
        let tunedResult = PreviewCompositionBuilder.applyCursorTrajectory(
            to: [unpinned],
            cursorTrajectory: input,
            tuning: TuningSettings(
                cameraTau: 0.10,
                settle: 1.0,
                deadzoneFraction: 0.6,
                edgeCushion: 1.0,
                maxPanSpeed: 0.05
            )
        )[0].trajectory ?? []
        XCTAssertEqual(tunedResult, defaultResult,
                       "reference adaptive follow uses ZoomMotionConstants.autoFollowParams in both preview and export")
    }

    func test_applyCursorTrajectory_matchesAdaptiveFollowHelper() {
        let input: [MouseTrajectorySample] = (0...20).map { i in
            MouseTrajectorySample(
                timelineTime: 1.0 + 0.05 * Double(i),
                centerX: 0.20 + 0.40 * Double(i) / 20.0,
                centerY: 0.50
            )
        }
        let zoom = makeZoom(start: 1.0, duration: 1.0, anchorMode: .followCursor)
        let result = PreviewCompositionBuilder.applyCursorTrajectory(
            to: [zoom],
            cursorTrajectory: input
        )[0].trajectory ?? []
        let windowed = MouseTrajectory.window(input, timelineRange: zoom.timelineRange)
        let expected = MouseTrajectory.adaptiveFollow(
            windowed,
            params: ZoomMotionConstants.autoFollowParams
        )
        XCTAssertEqual(result, expected)
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
