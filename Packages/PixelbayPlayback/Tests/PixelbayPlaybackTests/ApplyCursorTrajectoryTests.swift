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
        trajectory: [ZoomTrajectorySample]? = nil
    ) -> EffectKeyframe {
        EffectKeyframe(
            kind: .zoom,
            timelineRange: TimeRange(
                start: .seconds(start),
                duration: .seconds(duration)
            ),
            trajectory: trajectory,
            anchorMode: anchorMode
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

    // Contract guard: applyCursorTrajectory must NOT re-smooth the input.
    // The caller (PreviewCompositionBuilder.build) runs MouseTrajectory.cameraDamped
    // once and feeds the smoothed result to both this helper AND the cursor
    // sprite render path — re-smoothing here would double-filter the
    // zoom-anchor while leaving the sprite singly-filtered, re-introducing
    // the sprite-races-ahead-of-camera bug the shared-smoothing design
    // exists to prevent.
    func test_inputAssumedPreSmoothed_windowingPreservesValues() {
        let input: [MouseTrajectorySample] = [
            MouseTrajectorySample(timelineTime: 1.0, centerX: 0.10, centerY: 0.20),
            MouseTrajectorySample(timelineTime: 1.5, centerX: 0.30, centerY: 0.40),
            MouseTrajectorySample(timelineTime: 2.0, centerX: 0.50, centerY: 0.60),
            MouseTrajectorySample(timelineTime: 2.5, centerX: 0.70, centerY: 0.80)
        ]
        let unpinned = makeZoom(start: 1.0, duration: 1.5, anchorMode: .followCursor)
        let result = PreviewCompositionBuilder.applyCursorTrajectory(
            to: [unpinned],
            cursorTrajectory: input
        )
        let trajectory = result[0].trajectory ?? []
        XCTAssertEqual(trajectory.count, input.count,
                       "all 4 input samples fall in [1.0, 2.5] — none should be dropped or filtered out")
        for (i, sample) in trajectory.enumerated() {
            XCTAssertEqual(sample.x, input[i].centerX, accuracy: 1e-9,
                           "windowing must not alter x — sample \(i) would change if smoothing were re-applied here")
            XCTAssertEqual(sample.y, input[i].centerY, accuracy: 1e-9,
                           "windowing must not alter y — sample \(i)")
        }
    }

    // Shared-smoothing contract: when the caller pre-smooths with
    // cameraDamped() and feeds the result to BOTH consumers, the
    // keyframe.trajectory samples carry the same (x, y) values as the
    // smoothed master at matching timestamps. This is what makes the
    // cursor sprite and zoom anchor track in lockstep (Screen Studio /
    // Loom behaviour) instead of the cursor sprite racing ahead of the
    // camera frame.
    func test_sharedSmoothing_spriteAndAnchorReadSamePositions() {
        let raw: [MouseTrajectorySample] = (0..<20).map {
            MouseTrajectorySample(
                timelineTime: Double($0) * 0.05,
                centerX: 0.30 + 0.02 * Double($0),
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
        // Each windowed sample's (x, y) must equal the smoothed master's
        // (centerX, centerY) at the matching absolute timeline timestamp.
        // window() shifts t by -kf.start but never alters x/y.
        for sample in trajectory {
            let absoluteT = sample.t + 0.2
            guard let source = smoothed.first(where: { abs($0.timelineTime - absoluteT) < 1e-9 }) else {
                XCTFail("no smoothed master sample at t=\(absoluteT)")
                continue
            }
            XCTAssertEqual(sample.x, source.centerX, accuracy: 1e-9,
                           "sprite (smoothed master) and anchor (windowed slice) must read identical x at t=\(absoluteT)")
            XCTAssertEqual(sample.y, source.centerY, accuracy: 1e-9,
                           "sprite and anchor must read identical y at t=\(absoluteT)")
        }
    }
}
