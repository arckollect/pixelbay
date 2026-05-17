import Foundation
import PixelbayCore
@testable import PixelbayEditor
import XCTest

final class IntentScorerTests: XCTestCase {

    // MARK: - Helpers

    /// Build a trajectory with `count` samples spaced `dt` seconds apart,
    /// driven by a position generator. Times are `start + i * dt`.
    private func trajectory(
        start: Double = 0,
        dt: Double = 1.0 / 30.0,
        count: Int,
        position: (Int) -> (Double, Double)
    ) -> [MouseTrajectorySample] {
        (0..<count).map { i in
            let (x, y) = position(i)
            return MouseTrajectorySample(timelineTime: start + Double(i) * dt, centerX: x, centerY: y)
        }
    }

    /// Stationary trajectory at `(x, y)` from `start` to `start + duration`,
    /// sampled at 30 Hz.
    private func stillTrajectory(start: Double, duration: Double, x: Double, y: Double)
        -> [MouseTrajectorySample] {
        let dt = 1.0 / 30.0
        let count = max(2, Int((duration / dt).rounded()) + 1)
        return trajectory(start: start, dt: dt, count: count) { _ in (x, y) }
    }

    /// Concatenate trajectory segments, preserving timestamps as provided.
    private func concat(_ segments: [[MouseTrajectorySample]]) -> [MouseTrajectorySample] {
        segments.flatMap { $0 }
    }

    // MARK: - 1. Dwell click fires

    func test_dwellClick_fires() {
        // Cursor still at (0.5, 0.5) from t=0 to t=2; click at t=1.
        let traj = stillTrajectory(start: 0, duration: 2.0, x: 0.5, y: 0.5)
        let clicks = [AutoZoomClick(timelineTime: 1.0, centerX: 0.5, centerY: 0.5)]
        let candidates = IntentScorer.score(rawClicks: clicks, trajectory: traj)
        let clickCandidate = candidates.first { $0.source == .click }
        XCTAssertNotNil(clickCandidate)
        XCTAssertGreaterThan(clickCandidate!.score, IntentScorer.fireThreshold)
        XCTAssertEqual(IntentScorer.selectFiring(candidates).count, 1)
    }

    // MARK: - 2. Fly-by click does not fire

    func test_flyByClick_doesNotFire() {
        // Cursor racing across the screen — 1.0 norm-units/s — through and past t=1.
        let dt = 1.0 / 30.0
        let count = 90 // 3 seconds of motion
        let traj = trajectory(dt: dt, count: count) { i in
            (Double(i) * dt * 1.0, 0.5) // 1.0 norm/s in x
        }
        let clicks = [AutoZoomClick(timelineTime: 1.0, centerX: 1.0, centerY: 0.5)]
        let candidates = IntentScorer.score(rawClicks: clicks, trajectory: traj)
        let click = candidates.first { $0.source == .click }!
        XCTAssertLessThan(click.score, IntentScorer.fireThreshold,
                          "fast pre-window + cursor doesn't linger after = below threshold")
        XCTAssertTrue(IntentScorer.selectFiring(candidates).isEmpty,
                      "fly-by click should not fire")
    }

    // MARK: - 3. Click then move away does not fire

    func test_clickThenMoveAway_doesNotFire() {
        // Still pre-window (t=0..1), click at t=1, then cursor races off in post-window.
        let pre = stillTrajectory(start: 0, duration: 1.0, x: 0.5, y: 0.5)
        let dt = 1.0 / 30.0
        let postCount = 30
        let post = (1..<postCount).map { i in
            MouseTrajectorySample(
                timelineTime: 1.0 + Double(i) * dt,
                centerX: 0.5 + Double(i) * dt * 1.5, // 1.5 norm/s away
                centerY: 0.5
            )
        }
        let traj = concat([pre, post])
        let clicks = [AutoZoomClick(timelineTime: 1.0, centerX: 0.5, centerY: 0.5)]
        let candidates = IntentScorer.score(rawClicks: clicks, trajectory: traj)
        let click = candidates.first { $0.source == .click }!
        XCTAssertLessThan(click.sPost, 0.5)
        XCTAssertTrue(IntentScorer.selectFiring(candidates).isEmpty,
                      "click followed by departure should not fire")
    }

    // MARK: - 4. Deceleration to rest fires (no click)

    func test_decelToRest_fires() {
        // Fast motion t=0..0.5s (0.6 norm/s), then still at (0.5, 0) t=0.5..1.5s.
        let dt = 1.0 / 30.0
        var samples: [MouseTrajectorySample] = []
        let fastCount = 15 // ~0.5s
        for i in 0..<fastCount {
            samples.append(MouseTrajectorySample(
                timelineTime: Double(i) * dt,
                centerX: Double(i) * dt * 0.6,
                centerY: 0.0
            ))
        }
        let stillStart = samples.last!.timelineTime
        let stillX = samples.last!.centerX
        let stillCount = 60 // ~2s of stillness
        for i in 1...stillCount {
            samples.append(MouseTrajectorySample(
                timelineTime: stillStart + Double(i) * dt,
                centerX: stillX,
                centerY: 0.0
            ))
        }
        let candidates = IntentScorer.score(rawClicks: [], trajectory: samples)
        let decelFires = candidates.filter { $0.source == .decel && $0.score >= IntentScorer.fireThreshold }
        XCTAssertGreaterThanOrEqual(decelFires.count, 1, "decel-to-rest should produce a firing candidate")
        XCTAssertEqual(IntentScorer.selectFiring(candidates).count, 1)
    }

    // MARK: - 5. Repeated same spot — novelty contribution is zeroed

    func test_repeatedSameSpot_noveltyDamped() {
        // Two well-formed dwell-clicks at the SAME location, 3s apart (past
        // cooldown). Second candidate's sNovelty drops to ~0.
        let traj = stillTrajectory(start: 0, duration: 5.0, x: 0.5, y: 0.5)
        let clicks = [
            AutoZoomClick(timelineTime: 1.0, centerX: 0.5, centerY: 0.5),
            AutoZoomClick(timelineTime: 4.0, centerX: 0.5, centerY: 0.5)
        ]
        let candidates = IntentScorer.score(rawClicks: clicks, trajectory: traj)
        let clickCandidates = candidates.filter { $0.source == .click }
        XCTAssertEqual(clickCandidates.count, 2)
        XCTAssertGreaterThan(clickCandidates[0].sNovelty, 0.9,
                             "first click sees an empty fired list → novelty ~1")
        XCTAssertLessThan(clickCandidates[1].sNovelty, 0.05,
                          "second click overlaps the first fire → novelty ~0")
    }

    // MARK: - 6. Cooldown drops the second fire

    func test_cooldown_dropsSecondFire() {
        // Two strong dwell-clicks 1.0s apart at different locations.
        // First location: (0.3, 0.5); second: (0.7, 0.5). Each gets its own
        // local stillness, but the 1.0s gap < 1.8s cooldown blocks the second.
        let dt = 1.0 / 30.0
        var samples: [MouseTrajectorySample] = []
        // Still at (0.3, 0.5) from t=0 to t=1.4s
        for i in 0...42 {
            samples.append(MouseTrajectorySample(timelineTime: Double(i) * dt, centerX: 0.3, centerY: 0.5))
        }
        // Still at (0.7, 0.5) from t=1.5s onward (jump approximated by next sample)
        for i in 45...90 {
            samples.append(MouseTrajectorySample(timelineTime: Double(i) * dt, centerX: 0.7, centerY: 0.5))
        }
        let clicks = [
            AutoZoomClick(timelineTime: 1.0, centerX: 0.3, centerY: 0.5),
            AutoZoomClick(timelineTime: 2.0, centerX: 0.7, centerY: 0.5)
        ]
        let candidates = IntentScorer.score(rawClicks: clicks, trajectory: samples)
        let clicked = candidates.filter { $0.source == .click }
        XCTAssertGreaterThanOrEqual(clicked[0].score, IntentScorer.fireThreshold)
        XCTAssertGreaterThanOrEqual(clicked[1].score, IntentScorer.fireThreshold)
        let fires = IntentScorer.selectFiring(candidates)
        XCTAssertEqual(fires.count, 1, "cooldown should block the second fire even though both candidates score above threshold")
        XCTAssertEqual(fires.first.map(\.timelineTime) ?? .nan, 1.0, accuracy: 1e-9)
    }

    // MARK: - 7. v3 sidecar (empty trajectory) — clicks pass on their own

    func test_emptyTrajectory_v3Sidecar() {
        // No moves array → all three trajectory-driven scores forced to 1.0.
        // Each click candidate scores 0.30 + 0.25 + 0.30 + 0.15·sNovelty.
        let clicks = [
            AutoZoomClick(timelineTime: 1.0, centerX: 0.2, centerY: 0.2),
            AutoZoomClick(timelineTime: 3.0, centerX: 0.8, centerY: 0.8)
        ]
        let candidates = IntentScorer.score(rawClicks: clicks, trajectory: [])
        XCTAssertEqual(candidates.count, 2)
        for c in candidates {
            XCTAssertEqual(c.sPre, 1.0)
            XCTAssertEqual(c.sDecel, 1.0)
            XCTAssertEqual(c.sPost, 1.0)
            XCTAssertGreaterThan(c.score, IntentScorer.fireThreshold)
        }
        let fires = IntentScorer.selectFiring(candidates)
        XCTAssertEqual(fires.count, 2, "two well-separated v3 clicks should both fire (past cooldown)")
    }
}
