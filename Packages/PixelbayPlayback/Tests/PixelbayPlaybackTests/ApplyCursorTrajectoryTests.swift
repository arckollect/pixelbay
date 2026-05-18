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

    // Anchor=cursor integration check: a follow-cursor keyframe's stored
    // trajectory must equal the windowed master sample-for-sample — no
    // smoothing, no lag. Confirms `applyCursorTrajectory` pipes the
    // windowed slice straight through (cursor always centred contract).
    func test_applyCursorTrajectory_followCursor_anchorEqualsCursor() {
        let input: [MouseTrajectorySample] = (0...20).map { i in
            MouseTrajectorySample(
                timelineTime: 1.0 + 0.05 * Double(i),
                centerX: 0.20 + 0.03 * Double(i),
                centerY: 0.50
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
        for (cursorSample, anchorSample) in zip(input, trajectory) {
            XCTAssertEqual(anchorSample.x, cursorSample.centerX, accuracy: 1e-12,
                           "anchor x must equal cursor x exactly — cursor always centred")
            XCTAssertEqual(anchorSample.y, cursorSample.centerY, accuracy: 1e-12,
                           "anchor y must equal cursor y exactly — cursor always centred")
        }
    }

    // Shared-smoothing contract: the stored trajectory is exactly
    // `window(smoothed)` — sprite reads the smoothed master directly,
    // anchor reads the windowed slice with no further transform applied
    // (cursor always centred). Pins the wiring so the composition build
    // stays the single source of truth for the anchor path.
    func test_anchorIsWindowOfSmoothedMaster() {
        let raw: [MouseTrajectorySample] = (0..<20).map {
            MouseTrajectorySample(
                timelineTime: Double($0) * 0.05,
                centerX: 0.10 + 0.04 * Double($0),
                centerY: 0.50
            )
        }
        let smoothed = MouseTrajectory.cameraDamped(raw)
        let unpinned = makeZoom(start: 0.2, duration: 0.6, anchorMode: .followCursor)
        let result = PreviewCompositionBuilder.applyCursorTrajectory(
            to: [unpinned],
            cursorTrajectory: smoothed
        )
        let trajectory = result[0].trajectory ?? []
        XCTAssertFalse(trajectory.isEmpty,
                       "smoothed samples in [0.2, 0.8] must populate the keyframe trajectory")
        let expected = MouseTrajectory.window(smoothed, timelineRange: unpinned.timelineRange)
        XCTAssertEqual(trajectory.count, expected.count)
        for (actual, expect) in zip(trajectory, expected) {
            XCTAssertEqual(actual.t, expect.t, accuracy: 1e-12)
            XCTAssertEqual(actual.x, expect.x, accuracy: 1e-12,
                           "anchor x must equal windowed smoothed master at t=\(actual.t)")
            XCTAssertEqual(actual.y, expect.y, accuracy: 1e-12,
                           "anchor y must equal windowed smoothed master at t=\(actual.t)")
        }
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
