import XCTest
@testable import PixelbayCore

final class MouseTrajectoryAnchorFollowTests: XCTestCase {

    // At zoomFactor 2.0 with the default `deadzoneFraction = 0.0` and
    // `safeZoneFraction = 0.80` (v5.5 onward — anchor is a continuous
    // soft spring, no inner no-force zone). Tests that exercise an
    // opt-in deadzone pass `deadzoneFraction: 0.55` explicitly and use
    // `optInHDead` for their geometry.
    private let hSafeAtZoom2 = 0.80 / 2.0 / 2.0  // 0.20
    private let optInDeadzoneFrac = 0.55
    private let optInHDeadAtZoom2 = 0.55 / 2.0 / 2.0  // 0.1375

    // MARK: - Empty / degenerate input

    func test_anchorFollow_emptyInput_returnsEmpty() {
        let out = MouseTrajectory.anchorFollow([], zoomFactor: 2.0)
        XCTAssertTrue(out.isEmpty)
    }

    func test_anchorFollow_singleSample_returnsSampleUnchanged() {
        let only = ZoomTrajectorySample(t: 0.0, x: 0.42, y: 0.58)
        let out = MouseTrajectory.anchorFollow([only], zoomFactor: 2.0)
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0].t, only.t, accuracy: 1e-12)
        XCTAssertEqual(out[0].x, only.x, accuracy: 1e-12)
        XCTAssertEqual(out[0].y, only.y, accuracy: 1e-12)
    }

    // MARK: - Opt-in deadzone (callers passing deadzoneFraction > 0)

    func test_anchorFollow_smallMotionInsideOptInDeadzone_anchorStaysPut() {
        // Caller explicitly opts into a 0.55 deadzone (the v5.4 setting,
        // kept available as a knob even though v5.5 defaults to 0).
        // Cursor wanders within ±0.05 of the start position, entirely
        // inside the 0.1375 deadzone half-width at zoom 2. Spring exerts
        // no force inside the opt-in deadzone, so the anchor must not drift.
        let start = ZoomTrajectorySample(t: 0.0, x: 0.50, y: 0.50)
        let samples: [ZoomTrajectorySample] = [
            start,
            ZoomTrajectorySample(t: 0.1, x: 0.52, y: 0.49),
            ZoomTrajectorySample(t: 0.2, x: 0.54, y: 0.51),
            ZoomTrajectorySample(t: 0.3, x: 0.55, y: 0.53),
            ZoomTrajectorySample(t: 0.4, x: 0.53, y: 0.54),
            ZoomTrajectorySample(t: 0.5, x: 0.48, y: 0.47)
        ]
        let out = MouseTrajectory.anchorFollow(
            samples,
            zoomFactor: 2.0,
            deadzoneFraction: optInDeadzoneFrac
        )
        for sample in out.dropFirst() {
            XCTAssertEqual(sample.x, start.x, accuracy: 1e-6,
                           "anchor must hold steady while cursor wanders inside the opt-in deadzone")
            XCTAssertEqual(sample.y, start.y, accuracy: 1e-6)
        }
    }

    // MARK: - Default continuous soft spring (v5.5 production path)

    func test_anchorFollow_noDeadzone_anchorTracksAtRelaxedTau() {
        // With deadzoneFraction = 0 (the default), the spring is always
        // engaged. A cursor sustained at constant velocity inside the
        // safe zone produces a measurable but bounded steady-state lag:
        // ≈ 2·v·τ_relaxed = 2·0.20·0.18 = 0.072 norm-units. The exact
        // value depends on the boundary-adaptive τ ramp (τ tightens as
        // cursor approaches the wall, reducing actual lag below the
        // closed-form bound) — assert it's measurable AND ≤ hSafe.
        let v = 0.20
        let duration = 4.0
        let dt = 0.02
        let count = Int(duration / dt)
        let samples: [ZoomTrajectorySample] = (0...count).map { i in
            let t = Double(i) * dt
            return ZoomTrajectorySample(t: t, x: 0.50 + v * t, y: 0.5)
        }
        let out = MouseTrajectory.anchorFollow(samples, zoomFactor: 2.0)
        let lag = samples.last!.x - out.last!.x
        XCTAssertGreaterThan(lag, 0.0,
                             "continuous spring must produce measurable trailing lag during sustained motion")
        XCTAssertLessThanOrEqual(lag, hSafeAtZoom2 + 1e-9,
                                 "lag must respect the safe-zone invariant even without a deadzone")
    }

    // MARK: - Steady-state lag past the opt-in deadzone

    func test_anchorFollow_sustainedMotionPastOptInDeadzone_anchorTracksWithBoundedLag() {
        // With an opt-in 0.55 deadzone, cursor moves at v = 0.20 norm/s
        // for 4 s. Spring engages once the cursor crosses the deadzone
        // edge; lag stays bounded between the deadzone half-width (no
        // spring force before then) and the safe-zone half-width (hard
        // barrier).
        let v = 0.20
        let duration = 4.0
        let dt = 0.02
        let count = Int(duration / dt)
        let samples: [ZoomTrajectorySample] = (0...count).map { i in
            let t = Double(i) * dt
            return ZoomTrajectorySample(t: t, x: 0.10 + v * t, y: 0.5)
        }
        let out = MouseTrajectory.anchorFollow(
            samples,
            zoomFactor: 2.0,
            deadzoneFraction: optInDeadzoneFrac
        )
        let lag = samples.last!.x - out.last!.x
        XCTAssertGreaterThan(lag, optInHDeadAtZoom2 - 1e-9,
                             "after sustained motion the cursor must have exited the opt-in deadzone, producing measurable lag")
        XCTAssertLessThanOrEqual(lag, hSafeAtZoom2 + 1e-9,
                                 "anchor lag must never exceed the safe-zone half-width")
    }

    // MARK: - Safe-zone invariant

    func test_anchorFollow_safeZoneInvariant_cursorNeverEscapesSafeZone() {
        // Fast cursor sweep — even at sweep speed the hard barrier must
        // keep |cursor - anchor| ≤ hSafe on every sample.
        let dt = 0.01
        let count = 200
        let samples: [ZoomTrajectorySample] = (0...count).map { i in
            let t = Double(i) * dt
            let x = max(0.0, min(1.0, t * 0.5))
            return ZoomTrajectorySample(t: t, x: x, y: 0.5)
        }
        let out = MouseTrajectory.anchorFollow(samples, zoomFactor: 2.0)
        for (cursor, anchor) in zip(samples, out) {
            XCTAssertLessThanOrEqual(abs(cursor.x - anchor.x), hSafeAtZoom2 + 1e-9,
                                     "cursor must remain inside the safe zone (x-axis)")
            XCTAssertLessThanOrEqual(abs(cursor.y - anchor.y), hSafeAtZoom2 + 1e-9,
                                     "cursor must remain inside the safe zone (y-axis)")
        }
    }

    func test_anchorFollow_teleport_hardBarrierClampsAnchorToSafeZone() {
        // Synthetic teleport: cursor jumps 0.5 in one sample. Spring
        // cannot catch up, so the hard barrier must clamp the anchor
        // to cursor ± hSafe.
        let samples: [ZoomTrajectorySample] = [
            ZoomTrajectorySample(t: 0.0, x: 0.2, y: 0.5),
            ZoomTrajectorySample(t: 0.02, x: 0.7, y: 0.5)
        ]
        let out = MouseTrajectory.anchorFollow(samples, zoomFactor: 2.0)
        XCTAssertLessThanOrEqual(abs(samples[1].x - out[1].x), hSafeAtZoom2 + 1e-9,
                                 "hard barrier must clamp anchor inside safe zone after teleport")
        XCTAssertEqual(out[1].x, 0.7 - hSafeAtZoom2, accuracy: 1e-6,
                       "anchor must sit exactly at the trailing safe-zone wall after a forward teleport")
    }

    // MARK: - Monotonicity under sustained motion

    func test_anchorFollow_monotoneInput_producesMonotoneAnchor() {
        // Constant-velocity cursor sweep. The critically-damped spring
        // must produce a monotone anchor output — no plateaus, no
        // oscillations. Holds regardless of deadzone setting (with
        // deadzone=0 the spring is always engaged; with a non-zero
        // deadzone the anchor stays at its initial position until the
        // cursor crosses the deadzone, then tracks monotonically).
        let dt = 0.02
        let count = 60
        let samples: [ZoomTrajectorySample] = (0...count).map { i in
            let t = Double(i) * dt
            return ZoomTrajectorySample(t: t, x: 0.30 + 0.50 * t / 1.2, y: 0.5)
        }
        let out = MouseTrajectory.anchorFollow(samples, zoomFactor: 2.0)
        // Find the first index where cursor has measurably exceeded the
        // deadzone radius from the spring's initial position; after that
        // the anchor must be non-decreasing.
        let firstActiveIdx = out.firstIndex { abs($0.x - out[0].x) > 1e-6 } ?? out.count
        for i in (firstActiveIdx + 1)..<out.count {
            XCTAssertGreaterThanOrEqual(out[i].x, out[i - 1].x - 1e-9,
                                        "anchor x must be non-decreasing once spring is engaged")
        }
    }

    // MARK: - Zoom-factor clamping

    func test_anchorFollow_zoomFactorBelowOne_clampedAsIfOne() {
        // zoomFactor < 1 has no smaller-than-source viewport; clamp to 1.0.
        let samples: [ZoomTrajectorySample] = (0...20).map { i in
            ZoomTrajectorySample(t: 0.02 * Double(i), x: 0.5 + 0.01 * Double(i), y: 0.5)
        }
        let outBelow = MouseTrajectory.anchorFollow(samples, zoomFactor: 0.5)
        let outOne = MouseTrajectory.anchorFollow(samples, zoomFactor: 1.0)
        XCTAssertEqual(outBelow.count, outOne.count)
        for (a, b) in zip(outBelow, outOne) {
            XCTAssertEqual(a.x, b.x, accuracy: 1e-12)
            XCTAssertEqual(a.y, b.y, accuracy: 1e-12)
        }
    }
}
