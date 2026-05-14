import Foundation

// Real-time detector for the "draw a small circle with the cursor" gesture
// used as an alternative to the ⌃⌘Z hotkey to log a `ZoomMark` mid-recording
// (slice #11.e). Pure-data: takes `Sample`s in normalised `[0…1]` cursor
// space, returns a `Detection` when the recent sliding window satisfies a
// circular-path fit; otherwise returns nil. No OS dependencies, no
// concurrency — caller (ClickLogger) provides actor isolation.
//
// Algorithm:
//   1. Maintain a sliding window of samples within the last `windowSeconds`.
//   2. Once the window holds ≥ `minSamples`, run a Kasa-style least-squares
//      circle fit on it (centered formulation; numerically stable).
//   3. Gate detection on three conditions: radius ∈ [minRadius, maxRadius],
//      max-residual / radius ≤ maxResidualFraction, and total signed angle
//      sweep around the fitted centre ≥ minAngleSweepRadians (default 270°).
//   4. On fire: emit the centre as the ZoomMark coords, start a cooldown,
//      and clear the window so the next gesture has to fully rebuild it.
//
// Defaults are tuned for a "deliberate small circle in ~500ms" — the cursor
// can wobble (≤30% residual), needs to actually go around (≥270° of arc),
// and the radius is bounded so neither tiny jitter nor "I'm just moving
// around the screen" trips it.
public struct CircleGestureDetector: Sendable {
    public struct Sample: Sendable, Equatable {
        public var timestamp: Double
        public var x: Double
        public var y: Double

        public init(timestamp: Double, x: Double, y: Double) {
            self.timestamp = timestamp
            self.x = x
            self.y = y
        }
    }

    public struct Detection: Sendable, Equatable {
        /// Timestamp of the sample that completed the gesture (matches the
        /// last ingested sample's timestamp). ClickLogger uses this verbatim
        /// for the emitted ZoomMark so timeline alignment matches mouse-move
        /// alignment exactly.
        public var timestamp: Double
        public var x: Double
        public var y: Double
        public var radius: Double

        public init(timestamp: Double, x: Double, y: Double, radius: Double) {
            self.timestamp = timestamp
            self.x = x
            self.y = y
            self.radius = radius
        }
    }

    public var windowSeconds: Double
    public var minSamples: Int
    public var minRadius: Double
    public var maxRadius: Double
    public var maxResidualFraction: Double
    public var minAngleSweepRadians: Double
    public var cooldownSeconds: Double

    private var window: [Sample]
    private var lastFiredAt: Double?

    public init(
        windowSeconds: Double = 0.5,
        minSamples: Int = 6,
        minRadius: Double = 0.015,
        maxRadius: Double = 0.10,
        maxResidualFraction: Double = 0.30,
        minAngleSweepRadians: Double = 4.712389,  // 270°
        cooldownSeconds: Double = 1.0
    ) {
        self.windowSeconds = windowSeconds
        self.minSamples = minSamples
        self.minRadius = minRadius
        self.maxRadius = maxRadius
        self.maxResidualFraction = maxResidualFraction
        self.minAngleSweepRadians = minAngleSweepRadians
        self.cooldownSeconds = cooldownSeconds
        self.window = []
        self.lastFiredAt = nil
    }

    /// Push a sample. Returns a `Detection` if the recent window satisfies
    /// the circle gates; nil otherwise. After firing, clears the internal
    /// window so the next gesture has to build up from scratch — combined
    /// with the cooldown, this prevents a single 360° gesture from emitting
    /// multiple marks as the window slides forward.
    public mutating func ingest(_ sample: Sample) -> Detection? {
        // Keep only samples within the lookback window. Insertion-order is
        // monotonically non-decreasing on `timestamp` from the caller, so a
        // front-drop is sufficient.
        window.append(sample)
        let cutoff = sample.timestamp - windowSeconds
        while let first = window.first, first.timestamp < cutoff {
            window.removeFirst()
        }

        if let last = lastFiredAt, sample.timestamp - last < cooldownSeconds {
            return nil
        }
        guard window.count >= minSamples else { return nil }
        guard let fit = Self.fitCircle(window) else { return nil }
        guard fit.radius >= minRadius, fit.radius <= maxRadius else { return nil }

        // Residual gate: every point should lie within maxResidualFraction
        // of the fitted radius, expressed as |r_i - r| / r.
        let maxDeviation = window.reduce(0.0) { acc, sample in
            let dx = sample.x - fit.cx
            let dy = sample.y - fit.cy
            let r = (dx * dx + dy * dy).squareRoot()
            return max(acc, abs(r - fit.radius))
        }
        guard maxDeviation / fit.radius <= maxResidualFraction else { return nil }

        // Angle-sweep gate: sum the signed shortest-arc deltas between
        // consecutive samples' angles around the fitted centre. A clean
        // circle has all deltas same-signed and sums to ±2π. Partial arcs
        // (line, L-shape, half-circle) fall short.
        let sweep = Self.signedAngleSweep(window, cx: fit.cx, cy: fit.cy)
        guard abs(sweep) >= minAngleSweepRadians else { return nil }

        lastFiredAt = sample.timestamp
        window.removeAll(keepingCapacity: true)
        return Detection(
            timestamp: sample.timestamp,
            x: fit.cx,
            y: fit.cy,
            radius: fit.radius
        )
    }

    /// Test seam — lets tests assert window state without making the field
    /// public.
    var debugWindowCount: Int { window.count }

    // MARK: - Least-squares circle fit (Kasa, centred form)

    fileprivate struct Fit {
        var cx: Double
        var cy: Double
        var radius: Double
    }

    fileprivate static func fitCircle(_ samples: [Sample]) -> Fit? {
        let n = Double(samples.count)
        guard n >= 3 else { return nil }

        // Centre the data so the normal-equations matrix is well-conditioned
        // (subtracting the mean reduces numerical range and avoids losing
        // precision when the circle sits far from origin).
        let meanX = samples.reduce(0.0) { $0 + $1.x } / n
        let meanY = samples.reduce(0.0) { $0 + $1.y } / n

        var suu = 0.0, suv = 0.0, svv = 0.0
        var suuu = 0.0, svvv = 0.0, suvv = 0.0, svuu = 0.0
        for s in samples {
            let u = s.x - meanX
            let v = s.y - meanY
            suu += u * u
            suv += u * v
            svv += v * v
            suuu += u * u * u
            svvv += v * v * v
            suvv += u * v * v
            svuu += v * u * u
        }

        // Solve the 2×2 system for the centre offset (uc, vc):
        //   [suu  suv] [uc]   [(suuu + suvv) / 2]
        //   [suv  svv] [vc] = [(svvv + svuu) / 2]
        let det = suu * svv - suv * suv
        guard abs(det) > 1e-12 else { return nil }
        let rhs1 = (suuu + suvv) / 2.0
        let rhs2 = (svvv + svuu) / 2.0
        let uc = (svv * rhs1 - suv * rhs2) / det
        let vc = (suu * rhs2 - suv * rhs1) / det

        let radiusSquared = uc * uc + vc * vc + (suu + svv) / n
        guard radiusSquared > 0 else { return nil }
        return Fit(
            cx: uc + meanX,
            cy: vc + meanY,
            radius: radiusSquared.squareRoot()
        )
    }

    // MARK: - Angle sweep

    fileprivate static func signedAngleSweep(_ samples: [Sample], cx: Double, cy: Double) -> Double {
        guard samples.count >= 2 else { return 0 }
        var previousAngle = atan2(samples[0].y - cy, samples[0].x - cx)
        var sweep = 0.0
        for i in 1..<samples.count {
            let angle = atan2(samples[i].y - cy, samples[i].x - cx)
            var delta = angle - previousAngle
            // Wrap to (-π, π] so the per-step delta is the shortest arc; a
            // path that crosses the discontinuity at ±π doesn't get counted
            // as a near-2π jump in the opposite direction.
            while delta > .pi { delta -= 2 * .pi }
            while delta < -.pi { delta += 2 * .pi }
            sweep += delta
            previousAngle = angle
        }
        return sweep
    }
}
