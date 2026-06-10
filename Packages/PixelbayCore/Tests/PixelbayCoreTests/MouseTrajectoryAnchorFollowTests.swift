import XCTest
@testable import PixelbayCore

final class MouseTrajectoryAnchorFollowTests: XCTestCase {

    // At zoomFactor 2.0 with the Phase 3d iter 2 defaults:
    // `deadzoneFraction = 0.0` and `safeZoneFraction = 0.30` (tightened
    // from 0.50 once `cameraDamped` was removed from the upstream anchor
    // path — the spring now sees a near-instant input and can hold the
    // cursor inside a much smaller safe zone). Tests that exercise an
    // opt-in deadzone pass it AND an explicit `safeZoneFraction: 0.80`
    // so the deadzone+safezone band stays wide enough for the original
    // assertions.
    private let hSafeAtZoom2 = 0.30 / 2.0 / 2.0  // 0.075
    private let optInDeadzoneFrac = 0.55
    private let optInSafeZoneFrac = 0.80
    private let optInHSafeAtZoom2 = 0.80 / 2.0 / 2.0  // 0.20
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
            deadzoneFraction: optInDeadzoneFrac,
            safeZoneFraction: optInSafeZoneFrac
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
        // safe zone produces a measurable but bounded steady-state lag.
        // Phase 3d iter 2 closed-form bound: ≈ 2·v·τ_relaxed = 2·0.20·0.05
        // = 0.020 norm-units, well inside the 0.075 safe-zone half-width.
        // Assert lag is measurable AND ≤ hSafe.
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
            deadzoneFraction: optInDeadzoneFrac,
            safeZoneFraction: optInSafeZoneFrac
        )
        let lag = samples.last!.x - out.last!.x
        XCTAssertGreaterThan(lag, optInHDeadAtZoom2 - 1e-9,
                             "after sustained motion the cursor must have exited the opt-in deadzone, producing measurable lag")
        XCTAssertLessThanOrEqual(lag, optInHSafeAtZoom2 + 1e-9,
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

    func test_anchorFollow_maxAnchorSpeedCanPreserveElasticTrailPastSoftSafeZone() {
        let samples: [ZoomTrajectorySample] = [
            ZoomTrajectorySample(t: 0.0, x: 0.2, y: 0.5),
            ZoomTrajectorySample(t: 0.02, x: 0.7, y: 0.5)
        ]
        let out = MouseTrajectory.anchorFollow(
            samples,
            zoomFactor: 2.0,
            maxAnchorSpeed: 1.0
        )
        XCTAssertLessThanOrEqual(abs(out[1].x - out[0].x), 0.02 + 1e-9,
                                 "speed-limited follow must glide instead of snapping to the safe-zone wall")
        XCTAssertGreaterThan(abs(samples[1].x - out[1].x), hSafeAtZoom2,
                             "finite speed limit may temporarily allow extra trail beyond the soft safe zone")
    }

    func test_spritePolished_customSlowMotionThresholdPreservesRawCursorPath() {
        let samples: [MouseTrajectorySample] = (0...8).map { i in
            MouseTrajectorySample(
                timelineTime: 0.05 * Double(i),
                centerX: 0.50 + 0.004 * Double(i),
                centerY: 0.50
            )
        }
        let out = MouseTrajectory.spritePolished(
            samples,
            windowSeconds: 0.085,
            speedLow: 0.20,
            speedHigh: 1.20,
            maxRawDeviation: 0.12
        )
        XCTAssertEqual(out, samples, "slow precise motion should remain authoritative and unsmoothed")
    }

    func test_spritePolished_fastJitterSmoothsInteriorButPreservesEndpoints() {
        let samples: [MouseTrajectorySample] = [
            MouseTrajectorySample(timelineTime: 0.00, centerX: 0.20, centerY: 0.50),
            MouseTrajectorySample(timelineTime: 0.02, centerX: 0.30, centerY: 0.57),
            MouseTrajectorySample(timelineTime: 0.04, centerX: 0.40, centerY: 0.43),
            MouseTrajectorySample(timelineTime: 0.06, centerX: 0.50, centerY: 0.57),
            MouseTrajectorySample(timelineTime: 0.08, centerX: 0.60, centerY: 0.43),
            MouseTrajectorySample(timelineTime: 0.10, centerX: 0.70, centerY: 0.50)
        ]
        let out = MouseTrajectory.spritePolished(
            samples,
            windowSeconds: 0.05,
            speedLow: 0.1,
            speedHigh: 0.2,
            maxRawDeviation: 0.08
        )
        XCTAssertEqual(out.first, samples.first)
        XCTAssertEqual(out.last, samples.last)
        XCTAssertLessThan(abs(out[2].centerY - 0.50), abs(samples[2].centerY - 0.50),
                          "fast zig-zag motion should be pulled toward a smoother path")
    }

    func test_spritePolished_extremeCornerSweepsCompressTowardPresentationPath() {
        let samples: [MouseTrajectorySample] = [
            MouseTrajectorySample(timelineTime: 0.00, centerX: 0.50, centerY: 0.50),
            MouseTrajectorySample(timelineTime: 0.02, centerX: 0.05, centerY: 0.95),
            MouseTrajectorySample(timelineTime: 0.04, centerX: 0.95, centerY: 0.05),
            MouseTrajectorySample(timelineTime: 0.06, centerX: 0.05, centerY: 0.95),
            MouseTrajectorySample(timelineTime: 0.08, centerX: 0.95, centerY: 0.05),
            MouseTrajectorySample(timelineTime: 0.10, centerX: 0.50, centerY: 0.50)
        ]

        let out = MouseTrajectory.spritePolished(samples)
        let interior = out.dropFirst().dropLast()

        XCTAssertEqual(out.first, samples.first)
        XCTAssertEqual(out.last, samples.last)
        XCTAssertGreaterThan(interior.map(\.centerX).min() ?? 0, 0.25)
        XCTAssertLessThan(interior.map(\.centerX).max() ?? 1, 0.75)
        XCTAssertGreaterThan(interior.map(\.centerY).min() ?? 0, 0.25)
        XCTAssertLessThan(interior.map(\.centerY).max() ?? 1, 0.75)
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

    // MARK: - Scenes-merge boundary (polish 2026-05-27)

    func test_anchorFollow_sceneBoundary_snapsInsteadOfChasing() {
        // Two recordings concatenated back-to-back via ScenesMerger.
        // Scene 1 has the cursor in the upper-left and barely moves;
        // scene 2 picks up with the cursor in the lower-right. Without
        // the boundary snap, the spring would carry over its scene-1
        // anchor and chase scene-2's position over the next ~50-100 ms
        // — visible camera lag at every scene cut. With the snap, the
        // anchor jumps to scene 2's first sample so the spring resumes
        // from the right place.
        var samples: [ZoomTrajectorySample] = []
        // Scene 1: cursor near (0.2, 0.2), barely moving for 1 s.
        for i in 0...20 {
            samples.append(ZoomTrajectorySample(t: 0.05 * Double(i), x: 0.2, y: 0.2))
        }
        // Scene 2 starts at the SAME timeline time as scene 1's last
        // sample (back-to-back per ScenesMerger), cursor jumps to
        // (0.8, 0.8). Then 1 s of stationary cursor.
        let boundaryT = samples.last!.t
        samples.append(ZoomTrajectorySample(t: boundaryT, x: 0.8, y: 0.8))
        for i in 1...20 {
            samples.append(ZoomTrajectorySample(t: boundaryT + 0.05 * Double(i), x: 0.8, y: 0.8))
        }
        let out = MouseTrajectory.anchorFollow(samples, zoomFactor: 2.0)
        // Sample 1 frame after the boundary — the anchor should already
        // be at (or very close to) scene 2's position, not still
        // lingering near (0.2, 0.2). Without the snap fix, the spring
        // would put the anchor at roughly the midpoint after one frame.
        let postBoundary = out[samples.count - 20]   // first sample after the snap
        XCTAssertEqual(postBoundary.x, 0.8, accuracy: 0.01,
                       "anchor must snap to scene 2's starting position at the boundary")
        XCTAssertEqual(postBoundary.y, 0.8, accuracy: 0.01)
    }

    func test_anchorFollow_sameTimestampSmallMove_doesNotSnap() {
        // Sanity check: two samples at the same time with a tiny
        // position delta (< 5% of normalized screen) are NOT treated
        // as a scene boundary — they could be a clock-quantization
        // artifact within a single recording. Anchor stays put.
        let samples: [ZoomTrajectorySample] = [
            ZoomTrajectorySample(t: 0.0, x: 0.5, y: 0.5),
            ZoomTrajectorySample(t: 0.01, x: 0.5, y: 0.5),
            ZoomTrajectorySample(t: 0.01, x: 0.51, y: 0.5),   // same-t, tiny move
            ZoomTrajectorySample(t: 0.02, x: 0.51, y: 0.5),
        ]
        let out = MouseTrajectory.anchorFollow(samples, zoomFactor: 2.0)
        // After the same-timestamp tiny-move sample, anchor should
        // still be near 0.5 (not snapped to 0.51 — that's the
        // pre-boundary-fix behavior we want to preserve for in-
        // recording samples).
        XCTAssertEqual(out[2].x, 0.5, accuracy: 0.01,
                       "tiny moves at the same timestamp must NOT trigger the boundary snap")
    }

    // MARK: - Anticipated targets (offline future-window camera path)

    /// 30 Hz rightward sweep from x=0.2 to x=0.8 over 1 s, then held for
    /// `holdSeconds`. y constant at 0.5.
    private func sweepThenHold(holdSeconds: Double = 1.0) -> [ZoomTrajectorySample] {
        var samples: [ZoomTrajectorySample] = []
        let dt = 1.0 / 30.0
        var t = 0.0
        while t <= 1.0 {
            samples.append(ZoomTrajectorySample(t: t, x: 0.2 + 0.6 * t, y: 0.5))
            t += dt
        }
        let last = samples[samples.count - 1]
        var ht = last.t + dt
        while ht <= last.t + holdSeconds {
            samples.append(ZoomTrajectorySample(t: ht, x: last.x, y: last.y))
            ht += dt
        }
        return samples
    }

    func test_anticipatedTargets_stationaryCursor_isIdentity() {
        let samples = (0..<60).map {
            ZoomTrajectorySample(t: Double($0) / 30.0, x: 0.4, y: 0.6)
        }
        let out = MouseTrajectory.anticipatedTargets(samples)
        XCTAssertEqual(out.count, samples.count)
        for (a, b) in zip(samples, out) {
            XCTAssertEqual(a.x, b.x, accuracy: 1e-9)
            XCTAssertEqual(a.y, b.y, accuracy: 1e-9)
        }
    }

    func test_anticipatedTargets_midSweep_targetLeadsCursor() {
        let samples = sweepThenHold()
        let out = MouseTrajectory.anticipatedTargets(
            samples, halfWindowSeconds: 0.25, leadSeconds: 0.07
        )
        // Mid-sweep (t = 0.5): rightward motion, forward-biased window →
        // the target must sit AHEAD of the cursor along +x.
        let mid = samples.firstIndex { $0.t >= 0.5 }!
        XCTAssertGreaterThan(out[mid].x, samples[mid].x + 0.01,
                             "anticipated target must lead the cursor mid-sweep")
        XCTAssertEqual(out[mid].y, 0.5, accuracy: 1e-9)
    }

    func test_anticipatedTargets_nearLanding_convergesOntoLandingPoint() {
        let samples = sweepThenHold(holdSeconds: 1.0)
        let out = MouseTrajectory.anticipatedTargets(
            samples, halfWindowSeconds: 0.25, leadSeconds: 0.07
        )
        // Shortly before the sweep ends (t = 0.9, cursor at 0.74) the
        // target should already be pulled toward the landing point (0.8)
        // — the camera settles WITH the cursor, not after it.
        let nearEnd = samples.firstIndex { $0.t >= 0.9 }!
        XCTAssertGreaterThan(out[nearEnd].x, samples[nearEnd].x,
                             "target should be drawn toward the landing point")
        XCTAssertLessThanOrEqual(out[nearEnd].x, 0.8 + 1e-9,
                                 "averaging can never overshoot the landing point")
        // Well into the hold, the target must sit exactly on the cursor.
        let held = samples.firstIndex { $0.t >= 1.6 }!
        XCTAssertEqual(out[held].x, 0.8, accuracy: 1e-6)
    }

    func test_anticipatedTargets_doesNotAverageAcrossSceneBoundary() {
        // Scene 1 holds at (0.2, 0.2); scene 2 holds at (0.8, 0.8); the
        // merge places them back-to-back at t = 1.0. The window must not
        // blend positions across the cut.
        var samples: [ZoomTrajectorySample] = []
        let dt = 1.0 / 30.0
        var t = 0.0
        while t < 1.0 {
            samples.append(ZoomTrajectorySample(t: t, x: 0.2, y: 0.2))
            t += dt
        }
        let boundaryT = samples[samples.count - 1].t
        var t2 = boundaryT
        while t2 < boundaryT + 1.0 {
            samples.append(ZoomTrajectorySample(t: t2, x: 0.8, y: 0.8))
            t2 += dt
        }
        let out = MouseTrajectory.anticipatedTargets(
            samples, halfWindowSeconds: 0.25, leadSeconds: 0.07
        )
        // Last scene-1 sample: window reaches into scene 2's samples by
        // time, but the boundary guard must stop it.
        let lastScene1 = samples.lastIndex { $0.x < 0.5 }!
        XCTAssertEqual(out[lastScene1].x, 0.2, accuracy: 1e-6,
                       "anticipation must not smear the target across a scene cut")
        let firstScene2 = lastScene1 + 1
        XCTAssertEqual(out[firstScene2].x, 0.8, accuracy: 1e-6)
    }

    func test_anchorFollow_withAnticipatedTargets_safeZoneInvariantStillHolds() {
        // Aggressive anticipation must never let the REAL cursor escape
        // the safe zone — the hard barrier keys off the cursor samples,
        // not the anticipated targets.
        let samples = sweepThenHold()
        let targets = MouseTrajectory.anticipatedTargets(
            samples, halfWindowSeconds: 0.4, leadSeconds: 0.2
        )
        let out = MouseTrajectory.anchorFollow(
            samples,
            zoomFactor: 2.0,
            anticipatedTargets: targets
        )
        for (cursor, anchor) in zip(samples, out) {
            XCTAssertLessThanOrEqual(
                abs(cursor.x - anchor.x), hSafeAtZoom2 + 1e-9,
                "cursor escaped the safe zone at t=\(cursor.t)"
            )
            XCTAssertLessThanOrEqual(abs(cursor.y - anchor.y), hSafeAtZoom2 + 1e-9)
        }
    }

    func test_anchorFollow_withAnticipatedTargets_settlesOnLandingPoint() {
        let samples = sweepThenHold(holdSeconds: 1.5)
        let targets = MouseTrajectory.anticipatedTargets(
            samples, halfWindowSeconds: 0.25, leadSeconds: 0.07
        )
        let out = MouseTrajectory.anchorFollow(
            samples,
            zoomFactor: 2.0,
            anticipatedTargets: targets
        )
        // By the end of the hold the anchor must have converged onto the
        // landing point (0.8, 0.5).
        let last = out[out.count - 1]
        XCTAssertEqual(last.x, 0.8, accuracy: 0.005)
        XCTAssertEqual(last.y, 0.5, accuracy: 0.005)
    }
}
