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

    // Lazy-follow integration check: a follow-cursor keyframe whose master
    // cursor sweeps a long distance must produce a stored trajectory whose
    // last sample lags the cursor's last sample by the expected deadzone
    // half-width. Confirms `applyCursorTrajectory` actually pipes through
    // `MouseTrajectory.lazyFollow`, not just `window`.
    func test_applyCursorTrajectory_followCursor_outputIsLazyFollowed() {
        // Master cursor sweeps x: 0.20 → 0.80 over 1.0 s, keyframe covers
        // [1.0, 2.5] but the cursor samples live in [1.0, 2.0]; all
        // samples fall in the keyframe range.
        let input: [MouseTrajectorySample] = (0...20).map { i in
            MouseTrajectorySample(
                timelineTime: 1.0 + 0.05 * Double(i),
                centerX: 0.20 + 0.03 * Double(i),
                centerY: 0.50
            )
        }
        // Default zoomFactor on makeZoom = EffectKeyframe.init's default
        // (1.5). deadzone half-width: 0.5 / 2 / 1.5 = 0.166̄.
        let unpinned = makeZoom(start: 1.0, duration: 1.5, anchorMode: .followCursor)
        let result = PreviewCompositionBuilder.applyCursorTrajectory(
            to: [unpinned],
            cursorTrajectory: input
        )
        let trajectory = result[0].trajectory ?? []
        XCTAssertEqual(trajectory.count, input.count,
                       "all input samples lie inside the keyframe range — none should be dropped")
        XCTAssertEqual(trajectory[0].x, input[0].centerX, accuracy: 1e-9,
                       "anchor must seed at the first cursor sample")
        let halfX = 0.5 / 2.0 / 1.5
        let lastLag = input.last!.centerX - trajectory.last!.x
        XCTAssertEqual(lastLag, halfX, accuracy: 1e-9,
                       "after a sweep that fully traverses the deadzone, the anchor must trail the cursor by exactly halfX")
    }

    // Shared-smoothing contract: the windowed + lazy-followed slice is the
    // **lazy-follow of** the pre-smoothed master at matching timestamps —
    // sprite reads the smoothed master directly, anchor reads the windowed
    // slice with lazy-follow applied. Earlier this test asserted strict
    // equality (anchor == sprite); the Screen Studio look needs the anchor
    // to *lag* the sprite by the deadzone, which is what this test now
    // pins.
    func test_anchorIsLazyFollowOfSpriteSmoothing() {
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
        // Reconstruct the expected output: window the smoothed master to
        // the same keyframe range, then apply lazy-follow with the
        // keyframe's zoom factor. The applyCursorTrajectory output must
        // match this byte-for-byte.
        let expectedWindowed = MouseTrajectory.window(smoothed, timelineRange: unpinned.timelineRange)
        let expected = MouseTrajectory.lazyFollow(expectedWindowed, zoomFactor: unpinned.zoomFactor)
        XCTAssertEqual(trajectory.count, expected.count)
        for (actual, expect) in zip(trajectory, expected) {
            XCTAssertEqual(actual.t, expect.t, accuracy: 1e-12)
            XCTAssertEqual(actual.x, expect.x, accuracy: 1e-12,
                           "anchor x must equal lazy-follow of smoothed master at t=\(actual.t)")
            XCTAssertEqual(actual.y, expect.y, accuracy: 1e-12,
                           "anchor y must equal lazy-follow of smoothed master at t=\(actual.t)")
        }
        // Cross-check: cameraDamped here produces an outward sweep (x
        // grows monotonically), so the final anchor must lag the final
        // smoothed-master cursor by the deadzone half-width.
        let halfX = 0.5 / 2.0 / unpinned.zoomFactor
        let masterEndX = smoothed.last(where: { $0.timelineTime <= unpinned.timelineRange.end.seconds })!.centerX
        XCTAssertEqual(masterEndX - trajectory.last!.x, halfX, accuracy: 1e-9,
                       "anchor must trail the smoothed-master cursor by the deadzone half-width on monotonic outward sweeps")
    }
}
