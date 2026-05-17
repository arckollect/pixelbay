import Foundation
import PixelbayCore

/// One scored candidate for an auto-zoom-in. Produced by `IntentScorer.score`
/// from raw clicks and a master mouse trajectory; the final fire decision is
/// `IntentScorer.selectFiring` which applies threshold + cooldown.
///
/// `score` is the weighted sum used by `selectFiring`; the four component
/// scores are exposed for debugging and tests.
public struct IntentCandidate: Equatable, Sendable {
    public let timelineTime: Double
    public let centerX: Double           // norm [0,1]
    public let centerY: Double
    public let source: Source
    public let sPre: Double
    public let sDecel: Double
    public let sPost: Double
    public let sNovelty: Double

    public var score: Double {
        0.30 * sPre + 0.25 * sDecel + 0.30 * sPost + 0.15 * sNovelty
    }

    public enum Source: Sendable, Equatable { case click, decel }

    public init(
        timelineTime: Double,
        centerX: Double,
        centerY: Double,
        source: Source,
        sPre: Double,
        sDecel: Double,
        sPost: Double,
        sNovelty: Double
    ) {
        self.timelineTime = timelineTime
        self.centerX = centerX
        self.centerY = centerY
        self.source = source
        self.sPre = sPre
        self.sDecel = sDecel
        self.sPost = sPost
        self.sNovelty = sNovelty
    }
}

/// Unified intent-scoring detector for auto-zoom-ins.
///
/// Replaces the old `AutoZoomService.filterClicks` (dwell gate) + `AutoZoomService.decelerationZooms`
/// (synthetic clicks from velocity transitions) pair, which were two independent boolean filters
/// approximating the same "the speaker is deliberately pointing here" semantic and didn't agree
/// with each other. The scorer fuses click signal, deceleration profile, post-event stillness,
/// and spatial novelty into a single number, then a threshold + cooldown gate picks fires.
///
/// Two-step API:
///   1. `score(rawClicks:trajectory:)` — emits one annotated candidate per click and per
///      detected decel-to-rest transition, in timeline order.
///   2. `selectFiring(_:)` — returns the `AutoZoomClick`s that pass `score >= fireThreshold`
///      and respect the `cooldown` floor between fires.
///
/// The `score` pass internally simulates the same fire decision so that `sNovelty` is computed
/// only against candidates that would actually fire — `selectFiring` then deterministically
/// reproduces that decision.
public enum IntentScorer {

    public static let fireThreshold: Double = 0.55
    public static let cooldown: Double = 1.8

    // Windows
    private static let preWindow: Double = 0.4
    private static let postWindow: Double = 0.6
    private static let decelWindow: Double = 0.5
    private static let noveltyWindow: Double = 5.0

    // Thresholds
    private static let preStillVelocity: Double = 0.15
    private static let decelDropFullScale: Double = 0.35
    private static let postStillRadius: Double = 0.05

    // Decel candidate generation (matches the legacy `decelerationZooms` predicate)
    private static let decelStartVelocity: Double = 0.40
    private static let decelEndVelocity: Double = 0.05
    private static let decelLookback: Double = 0.50

    public static func score(
        rawClicks: [AutoZoomClick],
        trajectory: [MouseTrajectorySample]
    ) -> [IntentCandidate] {
        let trajectoryEmpty = trajectory.isEmpty
        let smoothedVelocity = computeSmoothedVelocity(trajectory)

        var pre: [(t: Double, x: Double, y: Double, source: IntentCandidate.Source)] = []
        pre.reserveCapacity(rawClicks.count + trajectory.count / 10)
        for c in rawClicks {
            pre.append((c.timelineTime, c.centerX, c.centerY, .click))
        }
        if !trajectoryEmpty {
            for d in detectDecels(trajectory: trajectory, smoothedVelocity: smoothedVelocity) {
                pre.append(d)
            }
        }
        pre.sort { $0.t < $1.t }

        var result: [IntentCandidate] = []
        result.reserveCapacity(pre.count)
        var fired: [(t: Double, x: Double, y: Double)] = []
        var lastFiredAt: Double = -.infinity

        for p in pre {
            let sPre: Double
            let sDecel: Double
            let sPost: Double
            if trajectoryEmpty {
                // v3 sidecars carry no `moves`. With no trajectory evidence either way,
                // treat the three trajectory-driven components as fully positive so the
                // candidate fires on click signal alone. Preserves Phase 3b behavior
                // where `filterClicks` was a no-op for click-only sidecars.
                sPre = 1.0
                sDecel = 1.0
                sPost = 1.0
            } else {
                sPre = computeSPre(t: p.t, trajectory: trajectory, smoothedVelocity: smoothedVelocity)
                sDecel = computeSDecel(t: p.t, trajectory: trajectory, smoothedVelocity: smoothedVelocity)
                sPost = computeSPost(t: p.t, x: p.x, y: p.y, trajectory: trajectory)
            }

            // Drop fires older than 5 s so novelty resets after a long gap.
            while let first = fired.first, p.t - first.t > noveltyWindow {
                fired.removeFirst()
            }
            let sNovelty = computeSNovelty(x: p.x, y: p.y, fired: fired)

            let candidate = IntentCandidate(
                timelineTime: p.t,
                centerX: p.x,
                centerY: p.y,
                source: p.source,
                sPre: sPre,
                sDecel: sDecel,
                sPost: sPost,
                sNovelty: sNovelty
            )
            result.append(candidate)

            if candidate.score >= fireThreshold && p.t - lastFiredAt >= cooldown {
                fired.append((p.t, p.x, p.y))
                lastFiredAt = p.t
            }
        }
        return result
    }

    public static func selectFiring(_ candidates: [IntentCandidate]) -> [AutoZoomClick] {
        var result: [AutoZoomClick] = []
        var lastFiredAt: Double = -.infinity
        for c in candidates {
            guard c.score >= fireThreshold else { continue }
            guard c.timelineTime - lastFiredAt >= cooldown else { continue }
            result.append(AutoZoomClick(
                timelineTime: c.timelineTime,
                centerX: c.centerX,
                centerY: c.centerY
            ))
            lastFiredAt = c.timelineTime
        }
        return result
    }

    // MARK: - Velocity

    /// Per-sample instantaneous velocity (norm-units/s), box-smoothed with radius 2
    /// (~5 samples, ~165 ms at 30 Hz). Matches the smoothing the legacy
    /// `decelerationZooms` used so candidate generation is byte-identical.
    private static func computeSmoothedVelocity(_ trajectory: [MouseTrajectorySample]) -> [Double] {
        guard trajectory.count >= 2 else {
            return Array(repeating: 0.0, count: trajectory.count)
        }
        var raw: [Double] = [0]
        raw.reserveCapacity(trajectory.count)
        for i in 1..<trajectory.count {
            let p = trajectory[i - 1]
            let s = trajectory[i]
            let dt = s.timelineTime - p.timelineTime
            guard dt > 0 else { raw.append(raw[i - 1]); continue }
            let dx = s.centerX - p.centerX
            let dy = s.centerY - p.centerY
            raw.append((dx * dx + dy * dy).squareRoot() / dt)
        }
        var smoothed = [Double](repeating: 0.0, count: raw.count)
        for i in 0..<raw.count {
            let lo = max(0, i - 2)
            let hi = min(raw.count - 1, i + 2)
            var sum = 0.0
            for k in lo...hi { sum += raw[k] }
            smoothed[i] = sum / Double(hi - lo + 1)
        }
        return smoothed
    }

    // MARK: - Candidate generation

    private static func detectDecels(
        trajectory: [MouseTrajectorySample],
        smoothedVelocity v: [Double]
    ) -> [(t: Double, x: Double, y: Double, source: IntentCandidate.Source)] {
        guard trajectory.count >= 3 else { return [] }
        var out: [(Double, Double, Double, IntentCandidate.Source)] = []
        for i in 1..<v.count {
            // Decel-to-rest crossing: prior sample above end-velocity, this one at-or-below.
            guard v[i - 1] > decelEndVelocity, v[i] <= decelEndVelocity else { continue }
            let sample = trajectory[i]
            // Require a genuinely-fast sample within the lookback window so we
            // don't fire on minor pauses inside slow drifts.
            var sawFast = false
            for j in stride(from: i - 1, through: 0, by: -1) {
                if sample.timelineTime - trajectory[j].timelineTime > decelLookback { break }
                if v[j] >= decelStartVelocity { sawFast = true; break }
            }
            guard sawFast else { continue }
            out.append((sample.timelineTime, sample.centerX, sample.centerY, .decel))
        }
        return out
    }

    // MARK: - Component scores

    /// Fraction of samples in `[t - preWindow, t]` whose smoothed velocity is below
    /// `preStillVelocity`. 1.0 = perfectly still pre-window. Returns 1.0 if no
    /// samples fall in the window (no contradicting evidence).
    private static func computeSPre(
        t: Double,
        trajectory: [MouseTrajectorySample],
        smoothedVelocity v: [Double]
    ) -> Double {
        let start = t - preWindow
        var count = 0
        var below = 0
        for i in 0..<trajectory.count {
            let st = trajectory[i].timelineTime
            if st < start { continue }
            if st > t { break }
            count += 1
            if v[i] < preStillVelocity { below += 1 }
        }
        if count == 0 { return 1.0 }
        return Double(below) / Double(count)
    }

    /// Velocity drop across `[t - decelWindow, t]`, normalized so a drop of
    /// `decelDropFullScale` saturates the score at 1.0. Returns 0.0 if no
    /// samples fall in the window (no evidence of intentional deceleration).
    private static func computeSDecel(
        t: Double,
        trajectory: [MouseTrajectorySample],
        smoothedVelocity v: [Double]
    ) -> Double {
        let start = t - decelWindow
        var maxV = 0.0
        var atV = 0.0
        var found = false
        for i in 0..<trajectory.count {
            let st = trajectory[i].timelineTime
            if st < start { continue }
            if st > t { break }
            found = true
            if v[i] > maxV { maxV = v[i] }
            atV = v[i]
        }
        if !found { return 0.0 }
        let drop = max(0.0, maxV - atV)
        return max(0.0, min(1.0, drop / decelDropFullScale))
    }

    /// Fraction of samples in `[t, t + postWindow]` whose distance from
    /// `(x, y)` is within `postStillRadius`. 1.0 = cursor lingered near the
    /// event location. Returns 1.0 if no samples fall in the window.
    private static func computeSPost(
        t: Double,
        x: Double,
        y: Double,
        trajectory: [MouseTrajectorySample]
    ) -> Double {
        let end = t + postWindow
        var count = 0
        var within = 0
        for sample in trajectory {
            if sample.timelineTime < t { continue }
            if sample.timelineTime > end { break }
            count += 1
            let dx = sample.centerX - x
            let dy = sample.centerY - y
            if (dx * dx + dy * dy).squareRoot() <= postStillRadius { within += 1 }
        }
        if count == 0 { return 1.0 }
        return Double(within) / Double(count)
    }

    /// 1.0 minus the highest spatial overlap (normalized Euclidean) against the
    /// already-fired candidates in `fired`. 1.0 = brand-new region; 0.0 =
    /// pixel-identical to a recent fire.
    private static func computeSNovelty(
        x: Double,
        y: Double,
        fired: [(t: Double, x: Double, y: Double)]
    ) -> Double {
        if fired.isEmpty { return 1.0 }
        let invSqrt2 = 1.0 / 2.0.squareRoot()
        var maxOverlap = 0.0
        for f in fired {
            let dx = x - f.x
            let dy = y - f.y
            let dist = (dx * dx + dy * dy).squareRoot()
            let overlap = max(0.0, min(1.0, 1.0 - dist * invSqrt2))
            if overlap > maxOverlap { maxOverlap = overlap }
        }
        return max(0.0, 1.0 - maxOverlap)
    }
}
