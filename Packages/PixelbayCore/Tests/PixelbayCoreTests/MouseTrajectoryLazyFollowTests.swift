import XCTest
@testable import PixelbayCore

final class MouseTrajectoryLazyFollowTests: XCTestCase {

    // MARK: - Empty / degenerate input

    func test_lazyFollow_emptyInput_returnsEmpty() {
        let out = MouseTrajectory.lazyFollow([], zoomFactor: 2.0)
        XCTAssertTrue(out.isEmpty)
    }

    func test_lazyFollow_singleSample_returnsSampleUnchanged() {
        let only = ZoomTrajectorySample(t: 0.0, x: 0.42, y: 0.58)
        let out = MouseTrajectory.lazyFollow([only], zoomFactor: 2.0)
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0].t, only.t, accuracy: 1e-12)
        XCTAssertEqual(out[0].x, only.x, accuracy: 1e-12)
        XCTAssertEqual(out[0].y, only.y, accuracy: 1e-12)
    }

    // MARK: - Behaviour inside / across the deadzone

    func test_lazyFollow_cursorInsideDeadzone_anchorStaysPut() {
        // At zoomFactor 2.0 and deadzoneFraction 0.50, the per-axis
        // half-width is (0.50 / 2) / 2.0 = 0.125. Wander within ±0.05 of the
        // start — well inside the deadzone — and the anchor must not move.
        let start = ZoomTrajectorySample(t: 0.0, x: 0.50, y: 0.50)
        let samples: [ZoomTrajectorySample] = [
            start,
            ZoomTrajectorySample(t: 0.05, x: 0.52, y: 0.49),
            ZoomTrajectorySample(t: 0.10, x: 0.54, y: 0.51),
            ZoomTrajectorySample(t: 0.15, x: 0.55, y: 0.53),
            ZoomTrajectorySample(t: 0.20, x: 0.53, y: 0.54),
            ZoomTrajectorySample(t: 0.25, x: 0.46, y: 0.47)
        ]
        let out = MouseTrajectory.lazyFollow(samples, zoomFactor: 2.0)
        XCTAssertEqual(out.count, samples.count)
        for sample in out {
            XCTAssertEqual(sample.x, start.x, accuracy: 1e-12,
                           "anchor must stay put while cursor wanders inside the deadzone")
            XCTAssertEqual(sample.y, start.y, accuracy: 1e-12)
        }
    }

    func test_lazyFollow_cursorCrossesEdge_anchorTrailsByDeadzoneHalfWidth() {
        // At zoomFactor 2.0, halfX = 0.125. Cursor sweeps from 0.3 → 0.7
        // along x. Anchor seeds at 0.3; while the cursor moves outward, the
        // anchor lags such that (cursor.x - anchor.x) == +halfX once the
        // cursor leaves the deadzone.
        let samples: [ZoomTrajectorySample] = (0...20).map { i in
            let frac = Double(i) / 20.0
            return ZoomTrajectorySample(t: 0.01 * Double(i),
                                        x: 0.3 + 0.4 * frac,
                                        y: 0.5)
        }
        let out = MouseTrajectory.lazyFollow(samples, zoomFactor: 2.0)
        XCTAssertEqual(out.count, samples.count)
        let halfX = 0.125
        // Skip i=0 (anchor seeded at cursor) and any sample whose cursor.x
        // is still inside [anchor - halfX, anchor + halfX]. For monotonic
        // outward motion past the deadzone, the steady-state lag is halfX.
        let last = out.count - 1
        let lag = samples[last].x - out[last].x
        XCTAssertEqual(lag, halfX, accuracy: 1e-9,
                       "anchor must trail the cursor by exactly the deadzone half-width on monotonic outward motion")
        // Sanity: anchor monotonically increases along x as cursor moves out.
        for i in 1..<out.count {
            XCTAssertGreaterThanOrEqual(out[i].x, out[i - 1].x - 1e-12,
                                        "anchor x must not regress while cursor moves outward")
        }
    }

    func test_lazyFollow_zoomFactorOne_anchorTracksOneToOne() {
        // At zoomFactor 1.0, halfX = 0.25. Cursor sweeps 0.5 → 1.0 in one
        // hop — past the deadzone in a single step. Anchor must jump to
        // cursor.x - halfX = 0.75.
        let samples: [ZoomTrajectorySample] = [
            ZoomTrajectorySample(t: 0.0, x: 0.5, y: 0.5),
            ZoomTrajectorySample(t: 0.1, x: 1.0, y: 0.5)
        ]
        let out = MouseTrajectory.lazyFollow(samples, zoomFactor: 1.0)
        XCTAssertEqual(out.count, 2)
        XCTAssertEqual(out[0].x, 0.5, accuracy: 1e-12)
        XCTAssertEqual(out[1].x, 0.75, accuracy: 1e-9,
                       "anchor must follow cursor by exactly the excess past the deadzone")
    }

    // MARK: - Zoom-factor clamping

    func test_lazyFollow_zoomFactorBelowOne_clampedAsIfOne() {
        // zoomFactor < 1 (no zoom or pull-out) should clamp to 1.0 — there
        // is no smaller-than-source viewport to bound, so we use the
        // single-screen half-width.
        let samples: [ZoomTrajectorySample] = [
            ZoomTrajectorySample(t: 0.0, x: 0.5, y: 0.5),
            ZoomTrajectorySample(t: 0.1, x: 1.0, y: 0.5)
        ]
        let outBelow = MouseTrajectory.lazyFollow(samples, zoomFactor: 0.5)
        let outOne = MouseTrajectory.lazyFollow(samples, zoomFactor: 1.0)
        XCTAssertEqual(outBelow.count, outOne.count)
        for (a, b) in zip(outBelow, outOne) {
            XCTAssertEqual(a.x, b.x, accuracy: 1e-12)
            XCTAssertEqual(a.y, b.y, accuracy: 1e-12)
        }
    }
}
