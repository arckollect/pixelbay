import XCTest
@testable import PixelbayCore

final class MouseTrajectoryAnchorFollowTests: XCTestCase {

    // glideFollow tests use zoomFactor 2.0 unless noted.
    private let hVisibleAtZoom2 = 0.48 / 2.0          // 0.24
    private let deadzoneRadiusAtZoom2 = 0.35 * 0.24   // default deadzoneFraction · visible half-extent

    // MARK: - Empty / degenerate input

    func test_glideFollow_emptyInput_returnsEmpty() {
        let out = MouseTrajectory.glideFollow([], zoomFactor: 2.0)
        XCTAssertTrue(out.isEmpty)
    }

    func test_glideFollow_singleSample_returnsSampleUnchanged() {
        let only = ZoomTrajectorySample(t: 0.0, x: 0.42, y: 0.58)
        let out = MouseTrajectory.glideFollow([only], zoomFactor: 2.0)
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0].t, only.t, accuracy: 1e-12)
        XCTAssertEqual(out[0].x, only.x, accuracy: 1e-12)
        XCTAssertEqual(out[0].y, only.y, accuracy: 1e-12)
    }

    // MARK: - Deadzone rest

    func test_glideFollow_cursorInsideDeadzone_cameraIsBitIdenticallyStill() {
        // Cursor wanders within ±0.05 of the start — inside the default
        // deadzone radius (0.35 · 0.24 = 0.084 at zoom 2). The camera must
        // not move AT ALL: resting means frozen, not "gently tracking".
        let start = ZoomTrajectorySample(t: 0.0, x: 0.50, y: 0.50)
        let samples: [ZoomTrajectorySample] = [
            start,
            ZoomTrajectorySample(t: 0.1, x: 0.52, y: 0.49),
            ZoomTrajectorySample(t: 0.2, x: 0.54, y: 0.51),
            ZoomTrajectorySample(t: 0.3, x: 0.55, y: 0.53),
            ZoomTrajectorySample(t: 0.4, x: 0.53, y: 0.54),
            ZoomTrajectorySample(t: 0.5, x: 0.48, y: 0.47)
        ]
        let out = MouseTrajectory.glideFollow(samples, zoomFactor: 2.0)
        for sample in out {
            XCTAssertEqual(sample.x, start.x, accuracy: 1e-12,
                           "camera must be perfectly still while cursor wanders inside the deadzone")
            XCTAssertEqual(sample.y, start.y, accuracy: 1e-12)
        }
    }

    // MARK: - Soft full recenter

    func test_glideFollow_exitingDeadzone_softFullRecenterThenRest() {
        // Cursor commits past the deadzone to (0.8, 0.5) and holds for 3 s.
        // The camera must glide all the way to the cursor (full recenter,
        // not a minimal edge-push) and come to rest near it.
        let dt = 1.0 / 60.0
        var samples: [ZoomTrajectorySample] = []
        for i in 0...30 {
            samples.append(ZoomTrajectorySample(
                t: Double(i) * dt,
                x: 0.40 + 0.40 * Double(i) / 30.0,
                y: 0.5
            ))
        }
        for i in 1...180 {
            samples.append(ZoomTrajectorySample(t: Double(30 + i) * dt, x: 0.80, y: 0.5))
        }
        let out = MouseTrajectory.glideFollow(samples, zoomFactor: 2.0)
        let final = out.last!
        XCTAssertEqual(final.x, 0.80, accuracy: 0.022,
                       "camera must recenter onto the cursor (within the rest radius)")
        // And once rested, it must be frozen — the last 30 samples identical.
        let tail = out.suffix(30)
        let tailFirst = tail.first!
        for sample in tail {
            XCTAssertEqual(sample.x, tailFirst.x, accuracy: 1e-12,
                           "camera must be fully at rest after recentering")
        }
    }

    func test_glideFollow_engagementRampPreventsKickOnDeadzoneExit() {
        // The instant the cursor crosses the deadzone edge, the camera's
        // first motion must be gentle — the spring force ramps in over
        // ~200 ms instead of arriving as a step impulse.
        let dt = 1.0 / 60.0
        var samples: [ZoomTrajectorySample] = []
        // Quick decisive move out of the deadzone, then continue.
        for i in 0...120 {
            samples.append(ZoomTrajectorySample(
                t: Double(i) * dt,
                x: 0.30 + min(0.4, 0.8 * Double(i) * dt),
                y: 0.5
            ))
        }
        let out = MouseTrajectory.glideFollow(samples, zoomFactor: 2.0)
        let firstMoveIdx = out.indices.first { out[$0].x != out[0].x }!
        // First two camera steps after engagement: well under the
        // unramped spring's first step.
        let step1 = out[firstMoveIdx].x - out[firstMoveIdx - 1].x
        let step2 = out[min(out.count - 1, firstMoveIdx + 1)].x - out[firstMoveIdx].x
        XCTAssertLessThan(abs(step1), 0.004, "engagement must fade in, not kick")
        XCTAssertLessThan(abs(step2), 0.008)
    }

    // MARK: - Constant feel at all cursor speeds

    func test_glideFollow_responseIsSpeedInvariant() {
        // THE core contract of the rework: the camera must NOT get
        // snappier when the cursor moves faster. With a constant tau the
        // steady-state lag of a ramp input is proportional to cursor
        // speed — so lag/v must match across speeds.
        func steadyStateLag(v: Double) -> Double {
            let dt = 0.01
            let duration = 5.0
            let count = Int(duration / dt)
            let samples: [ZoomTrajectorySample] = (0...count).map { i in
                let t = Double(i) * dt
                return ZoomTrajectorySample(t: t, x: 0.05 + v * t, y: 0.5)
            }
            let out = MouseTrajectory.glideFollow(
                samples,
                zoomFactor: 1.2,          // generous frame so the clamp never fires
                cameraTau: 0.35,
                settle: 0.0,
                deadzoneFraction: 0.0,    // no deadzone — pure spring response
                maxPanSpeed: 2.5,
                lookaheadSeconds: 0.0
            )
            return samples.last!.x - out.last!.x
        }
        let lagSlow = steadyStateLag(v: 0.08)
        let lagFast = steadyStateLag(v: 0.16)
        let normalizedSlow = lagSlow / 0.08
        let normalizedFast = lagFast / 0.16
        XCTAssertEqual(normalizedSlow, normalizedFast, accuracy: normalizedSlow * 0.15,
                       "lag/velocity must be speed-invariant — the camera keeps one weight at every speed")
    }

    // MARK: - Settle (drift-past) bounds

    func test_glideFollow_settleZero_neverOvershootsLanding() {
        let samples = sweepThenHold(holdSeconds: 3.0)
        let out = MouseTrajectory.glideFollow(
            samples,
            zoomFactor: 2.0,
            cameraTau: 0.35,
            settle: 0.0,
            deadzoneFraction: 0.0,
            maxPanSpeed: 2.5
        )
        let maxX = out.map(\.x).max() ?? 0
        XCTAssertLessThanOrEqual(maxX, 0.8 + 1e-3,
                                 "settle = 0 (critically damped) must never visibly pass the landing point")
    }

    func test_glideFollow_settleOne_driftsPastAndEasesBack_bounded() {
        let samples = sweepThenHold(holdSeconds: 3.0)
        let out = MouseTrajectory.glideFollow(
            samples,
            zoomFactor: 2.0,
            cameraTau: 0.35,
            settle: 1.0,
            deadzoneFraction: 0.0,
            maxPanSpeed: 2.5
        )
        let maxX = out.map(\.x).max() ?? 0
        XCTAssertGreaterThan(maxX, 0.8 + 0.002,
                             "settle = 1 should carry visible momentum past the landing")
        XCTAssertLessThanOrEqual(maxX, 0.8 + 0.08,
                                 "drift-past must read as weight, never as bounce")
        // It must still converge onto the landing point afterwards.
        XCTAssertEqual(out.last!.x, 0.8, accuracy: 0.022)
    }

    // MARK: - Visible-frame invariant

    func test_glideFollow_visibleFrameInvariant_cursorNeverEscapesFrame() {
        let dt = 0.01
        let count = 200
        let samples: [ZoomTrajectorySample] = (0...count).map { i in
            let t = Double(i) * dt
            let x = max(0.0, min(1.0, t * 0.5))
            return ZoomTrajectorySample(t: t, x: x, y: 0.5)
        }
        let out = MouseTrajectory.glideFollow(samples, zoomFactor: 2.0)
        for (cursor, anchor) in zip(samples, out) {
            XCTAssertLessThanOrEqual(abs(cursor.x - anchor.x), hVisibleAtZoom2 + 1e-9,
                                     "cursor must remain inside the visible frame (x-axis)")
            XCTAssertLessThanOrEqual(abs(cursor.y - anchor.y), hVisibleAtZoom2 + 1e-9,
                                     "cursor must remain inside the visible frame (y-axis)")
        }
    }

    func test_glideFollow_teleport_emergencyClampKeepsCursorVisible() {
        let samples: [ZoomTrajectorySample] = [
            ZoomTrajectorySample(t: 0.0, x: 0.2, y: 0.5),
            ZoomTrajectorySample(t: 0.02, x: 0.7, y: 0.5)
        ]
        let out = MouseTrajectory.glideFollow(samples, zoomFactor: 2.0)
        XCTAssertLessThanOrEqual(abs(samples[1].x - out[1].x), hVisibleAtZoom2 + 1e-9,
                                 "emergency clamp must keep the cursor visible after teleport")
        XCTAssertEqual(out[1].x, 0.7 - hVisibleAtZoom2, accuracy: 1e-6,
                       "camera must sit at the trailing visible-frame boundary after a forward teleport")
    }

    // MARK: - Pan speed cap

    func test_glideFollow_maxPanSpeedCapsVelocityWithoutKillingMomentum() {
        let dt = 0.05
        let samples: [ZoomTrajectorySample] = (0...40).map { i in
            ZoomTrajectorySample(
                t: Double(i) * dt,
                x: 0.20 + 0.55 * Double(i) / 40.0,
                y: 0.5
            )
        }
        let speedLimit = 0.35
        let out = MouseTrajectory.glideFollow(
            samples,
            zoomFactor: 1.5,
            cameraTau: 0.20,
            settle: 0.25,
            deadzoneFraction: 0.0,
            maxPanSpeed: speedLimit
        )
        var positiveMoves = 0
        for i in 1..<out.count {
            let move = out[i].x - out[i - 1].x
            XCTAssertLessThanOrEqual(abs(move), speedLimit * dt + 1e-9,
                                     "speed limit must cap integrated velocity")
            if move > 0.001 { positiveMoves += 1 }
        }
        XCTAssertGreaterThan(positiveMoves, 3,
                             "speed limiting should preserve forward momentum instead of zeroing velocity")
    }

    // MARK: - Monotonicity under sustained motion

    func test_glideFollow_monotoneInput_producesMonotoneCamera() {
        let dt = 0.02
        let count = 120
        let samples: [ZoomTrajectorySample] = (0...count).map { i in
            let t = Double(i) * dt
            return ZoomTrajectorySample(t: t, x: 0.20 + 0.25 * t, y: 0.5)
        }
        let out = MouseTrajectory.glideFollow(
            samples,
            zoomFactor: 2.0,
            settle: 0.0
        )
        let firstActiveIdx = out.firstIndex { abs($0.x - out[0].x) > 1e-6 } ?? out.count
        for i in (firstActiveIdx + 1)..<out.count {
            XCTAssertGreaterThanOrEqual(out[i].x, out[i - 1].x - 1e-9,
                                        "camera x must be non-decreasing once gliding (settle = 0)")
        }
    }

    // MARK: - Zoom-factor clamping

    func test_glideFollow_zoomFactorBelowOne_clampedAsIfOne() {
        let samples: [ZoomTrajectorySample] = (0...20).map { i in
            ZoomTrajectorySample(t: 0.02 * Double(i), x: 0.5 + 0.02 * Double(i), y: 0.5)
        }
        let outBelow = MouseTrajectory.glideFollow(samples, zoomFactor: 0.5)
        let outOne = MouseTrajectory.glideFollow(samples, zoomFactor: 1.0)
        XCTAssertEqual(outBelow.count, outOne.count)
        for (a, b) in zip(outBelow, outOne) {
            XCTAssertEqual(a.x, b.x, accuracy: 1e-12)
            XCTAssertEqual(a.y, b.y, accuracy: 1e-12)
        }
    }

    // MARK: - Lookahead

    func test_glideFollow_lookaheadReducesTrailingLagDuringSweep() {
        // Aiming the spring at the path's known future position should
        // measurably reduce the camera's mid-sweep lag vs no lookahead.
        let dt = 1.0 / 60.0
        let samples: [ZoomTrajectorySample] = (0...240).map { i in
            let t = Double(i) * dt
            return ZoomTrajectorySample(t: t, x: 0.10 + 0.18 * t, y: 0.5)
        }
        let plain = MouseTrajectory.glideFollow(
            samples, zoomFactor: 2.0, deadzoneFraction: 0.0, lookaheadSeconds: 0.0
        )
        let leading = MouseTrajectory.glideFollow(
            samples, zoomFactor: 2.0, deadzoneFraction: 0.0, lookaheadSeconds: 0.12
        )
        let plainLag = samples.last!.x - plain.last!.x
        let leadingLag = samples.last!.x - leading.last!.x
        XCTAssertLessThan(leadingLag, plainLag,
                          "lookahead should reduce trailing lag during a sustained sweep")
    }

    // MARK: - Scenes-merge boundary

    func test_glideFollow_sceneBoundary_snapsInsteadOfChasing() {
        var samples: [ZoomTrajectorySample] = []
        for i in 0...20 {
            samples.append(ZoomTrajectorySample(t: 0.05 * Double(i), x: 0.2, y: 0.2))
        }
        let boundaryT = samples.last!.t
        samples.append(ZoomTrajectorySample(t: boundaryT, x: 0.8, y: 0.8))
        for i in 1...20 {
            samples.append(ZoomTrajectorySample(t: boundaryT + 0.05 * Double(i), x: 0.8, y: 0.8))
        }
        let out = MouseTrajectory.glideFollow(samples, zoomFactor: 2.0)
        let postBoundary = out[samples.count - 20]
        XCTAssertEqual(postBoundary.x, 0.8, accuracy: 0.01,
                       "camera must snap to scene 2's starting position at the boundary")
        XCTAssertEqual(postBoundary.y, 0.8, accuracy: 0.01)
    }

    func test_glideFollow_sameTimestampSmallMove_doesNotSnap() {
        let samples: [ZoomTrajectorySample] = [
            ZoomTrajectorySample(t: 0.0, x: 0.5, y: 0.5),
            ZoomTrajectorySample(t: 0.01, x: 0.5, y: 0.5),
            ZoomTrajectorySample(t: 0.01, x: 0.51, y: 0.5),   // same-t, tiny move
            ZoomTrajectorySample(t: 0.02, x: 0.51, y: 0.5),
        ]
        let out = MouseTrajectory.glideFollow(samples, zoomFactor: 2.0)
        XCTAssertEqual(out[2].x, 0.5, accuracy: 0.01,
                       "tiny moves at the same timestamp must NOT trigger the boundary snap")
    }

    // MARK: - Test helpers

    /// 60 Hz rightward sweep from x=0.2 to x=0.8 over 1 s, then held for
    /// `holdSeconds`. y constant at 0.5.
    private func sweepThenHold(holdSeconds: Double = 1.0) -> [ZoomTrajectorySample] {
        var samples: [ZoomTrajectorySample] = []
        let dt = 1.0 / 60.0
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

    // MARK: - clickPinnedSmoothed (THE shared cursor path)

    func test_clickPinnedSmoothed_slowPreciseMotionStaysRaw() {
        let samples: [MouseTrajectorySample] = (0...8).map { i in
            MouseTrajectorySample(
                timelineTime: 0.05 * Double(i),
                centerX: 0.50 + 0.004 * Double(i),
                centerY: 0.50
            )
        }
        let out = MouseTrajectory.clickPinnedSmoothed(
            samples,
            windowSeconds: 0.30,
            travelCollapse: 1.0,
            speedLow: 0.20,
            speedHigh: 1.20
        )
        XCTAssertEqual(out, samples, "slow precise motion should remain authoritative and unsmoothed")
    }

    func test_clickPinnedSmoothed_fastJitterSmoothsInteriorButPreservesEndpoints() {
        let samples: [MouseTrajectorySample] = [
            MouseTrajectorySample(timelineTime: 0.00, centerX: 0.20, centerY: 0.50),
            MouseTrajectorySample(timelineTime: 0.02, centerX: 0.30, centerY: 0.57),
            MouseTrajectorySample(timelineTime: 0.04, centerX: 0.40, centerY: 0.43),
            MouseTrajectorySample(timelineTime: 0.06, centerX: 0.50, centerY: 0.57),
            MouseTrajectorySample(timelineTime: 0.08, centerX: 0.60, centerY: 0.43),
            MouseTrajectorySample(timelineTime: 0.10, centerX: 0.70, centerY: 0.50)
        ]
        let out = MouseTrajectory.clickPinnedSmoothed(
            samples,
            windowSeconds: 0.05,
            travelCollapse: 0.6
        )
        XCTAssertEqual(out.count, samples.count)
        XCTAssertLessThan(abs(out[2].centerY - 0.50), abs(samples[2].centerY - 0.50),
                          "fast zig-zag motion should be pulled toward a smoother path")
    }

    func test_clickPinnedSmoothed_edgeToEdgeSpamCollapsesAmplitude() {
        // Violent edge-to-edge spam at high collapse should shrink into a
        // small drift around the center of activity — Screen Studio's
        // signature amplitude collapse — not just slow down.
        var samples: [MouseTrajectorySample] = []
        for i in 0...60 {
            let phase = Double(i) * 0.5
            samples.append(MouseTrajectorySample(
                timelineTime: 0.016 * Double(i),
                centerX: 0.5 + 0.45 * sin(phase),
                centerY: 0.5
            ))
        }
        let collapsed = MouseTrajectory.clickPinnedSmoothed(
            samples,
            windowSeconds: 0.40,
            travelCollapse: 1.0
        )
        let honest = MouseTrajectory.clickPinnedSmoothed(
            samples,
            windowSeconds: 0.40,
            travelCollapse: 0.0
        )

        func interiorAmplitude(_ path: [MouseTrajectorySample]) -> Double {
            let xs = path.dropFirst(5).dropLast(5).map(\.centerX)
            return (xs.max() ?? 0) - (xs.min() ?? 0)
        }
        let rawAmplitude = interiorAmplitude(samples)
        XCTAssertLessThan(interiorAmplitude(collapsed), rawAmplitude * 0.30,
                          "full travel collapse should shrink spam to a small drift")
        // travelCollapse = 0 keeps deviation pinned to the honesty floor.
        for (raw, out) in zip(samples, honest) {
            let dx = out.centerX - raw.centerX
            let dy = out.centerY - raw.centerY
            XCTAssertLessThanOrEqual((dx * dx + dy * dy).squareRoot(), 0.021,
                                     "collapse = 0 must keep the path honest")
        }
        XCTAssertGreaterThan(interiorAmplitude(honest), rawAmplitude * 0.80,
                             "collapse = 0 should preserve nearly all raw amplitude")
    }

    func test_clickPinnedSmoothed_pixelExactAtClickInstant() {
        // Fast zig-zag with a click landing mid-travel: the smoothed path
        // deviates from raw during the spam, but the sample AT the click
        // time must be exactly the raw cursor position.
        var samples: [MouseTrajectorySample] = []
        for i in 0...60 {
            let phase = Double(i) * 0.5
            samples.append(MouseTrajectorySample(
                timelineTime: 0.016 * Double(i),
                centerX: 0.5 + 0.45 * sin(phase),
                centerY: 0.5
            ))
        }
        let clickIndex = 30
        let clickTime = samples[clickIndex].timelineTime
        let out = MouseTrajectory.clickPinnedSmoothed(
            samples,
            windowSeconds: 0.40,
            travelCollapse: 1.0,
            clickTimes: [clickTime],
            clickSnapWindow: 0.12
        )
        XCTAssertEqual(out[clickIndex].centerX, samples[clickIndex].centerX, accuracy: 1e-9,
                       "cursor must be exactly raw at the click instant")
        XCTAssertEqual(out[clickIndex].centerY, samples[clickIndex].centerY, accuracy: 1e-9)
        // Far from the click the stylized path deviates substantially.
        let farIndex = 50
        XCTAssertGreaterThan(abs(out[farIndex].centerX - samples[farIndex].centerX), 0.05,
                             "away from clicks the path should stay stylized")
    }

    func test_clickPinnedSmoothed_continuousAcrossSnapWindowEdges() {
        // The pin blend must ease in/out — no positional jump at the snap
        // window boundary.
        var samples: [MouseTrajectorySample] = []
        for i in 0...80 {
            let phase = Double(i) * 0.45
            samples.append(MouseTrajectorySample(
                timelineTime: 0.016 * Double(i),
                centerX: 0.5 + 0.4 * sin(phase),
                centerY: 0.5 + 0.2 * cos(phase * 0.7)
            ))
        }
        let clickTime = samples[40].timelineTime
        let out = MouseTrajectory.clickPinnedSmoothed(
            samples,
            windowSeconds: 0.35,
            travelCollapse: 1.0,
            clickTimes: [clickTime],
            clickSnapWindow: 0.15
        )
        for i in 1..<out.count {
            let dt = out[i].timelineTime - out[i - 1].timelineTime
            let dx = out[i].centerX - out[i - 1].centerX
            let dy = out[i].centerY - out[i - 1].centerY
            let step = (dx * dx + dy * dy).squareRoot()
            // Raw spam moves ~0.18/sample at the extreme; the pinned path
            // may locally move as fast as raw, but never discontinuously
            // faster.
            XCTAssertLessThanOrEqual(step, 0.25, "no jumps at snap-window edges (dt \(dt))")
        }
    }
}
