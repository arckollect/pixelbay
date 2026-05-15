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
}
