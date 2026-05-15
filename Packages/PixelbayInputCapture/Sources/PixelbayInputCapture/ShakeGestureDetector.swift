import Foundation

// Real-time detector for the "rapidly shake / wiggle the cursor" gesture —
// a third manual zoom-mark pathway alongside the ⌃⌘Z hotkey (keyboard) and
// `CircleGestureDetector` (slice #11.e). Mirrors macOS's "shake to find
// the cursor" interaction the user already has muscle-memory for. Pure-data
// like the circle detector: takes `Sample`s in normalised `[0…1]` cursor
// space, returns a `Detection` when the recent sliding window satisfies a
// shake fit; caller (`ClickLogger`) provides actor isolation.
//
// Algorithm:
//   1. Maintain a sliding window of samples within the last `windowSeconds`.
//   2. Once the window holds ≥ `minSamples`, pick the principal axis — the
//      one (x or y) with the greater range over the window. A deliberate
//      shake is dominantly one-axis even when the user isn't perfectly
//      horizontal; using the dominant axis lets the detector handle
//      diagonal shakes the same way without principal-component math.
//   3. Walk the projection on that axis and count direction reversals,
//      where each reversal requires the cursor to retrace ≥ `minLegLength`
//      from the running peak/trough (so jitter doesn't accumulate into a
//      false-positive). Each leg is by induction ≥ `minLegLength` as well.
//   4. Gate detection on: principal range ∈ [`minAmplitude`, `maxAmplitude`]
//      and reversal count ≥ `minReversals`.
//   5. On fire: emit the latest sample's coords as the ZoomMark anchor
//      (the cursor location *after* the shake — where the user wants to
//      focus), start a cooldown, and clear the window so the next gesture
//      has to fully rebuild it.
//
// Defaults are tuned for "back-forth-back-forth-back in ~400ms within a
// ~5-15% screen-width band" — fast enough to be deliberate, large enough
// to clear hand-tremor noise, small enough that "I'm dragging the cursor
// across the screen" doesn't trip it.
public struct ShakeGestureDetector: Sendable {
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
        /// Timestamp of the FIRST sample currently in the detector's sliding
        /// window at detection time — approximately when the user began the
        /// shake motion. `ClickLogger` uses this verbatim for the emitted
        /// `ZoomMark` so the editor can place the zoom range to begin with
        /// the gesture (zoom ramps in across the shake) rather than after
        /// it completes.
        public var timestamp: Double
        public var x: Double
        public var y: Double
        public var reversals: Int

        public init(timestamp: Double, x: Double, y: Double, reversals: Int) {
            self.timestamp = timestamp
            self.x = x
            self.y = y
            self.reversals = reversals
        }
    }

    public var windowSeconds: Double
    public var minSamples: Int
    public var minReversals: Int
    public var minLegLength: Double
    public var minAmplitude: Double
    public var maxAmplitude: Double
    public var cooldownSeconds: Double

    private var window: [Sample]
    private var lastFiredAt: Double?

    public init(
        windowSeconds: Double = 0.4,
        minSamples: Int = 8,
        minReversals: Int = 4,
        minLegLength: Double = 0.015,
        minAmplitude: Double = 0.04,
        maxAmplitude: Double = 0.25,
        cooldownSeconds: Double = 1.0
    ) {
        self.windowSeconds = windowSeconds
        self.minSamples = minSamples
        self.minReversals = minReversals
        self.minLegLength = minLegLength
        self.minAmplitude = minAmplitude
        self.maxAmplitude = maxAmplitude
        self.cooldownSeconds = cooldownSeconds
        self.window = []
        self.lastFiredAt = nil
    }

    /// Push a sample. Returns a `Detection` if the recent window satisfies
    /// the shake gates; nil otherwise. After firing, clears the internal
    /// window so the next gesture has to build up from scratch — combined
    /// with the cooldown, this prevents a single sustained shake from
    /// emitting multiple marks as the window slides forward.
    public mutating func ingest(_ sample: Sample) -> Detection? {
        window.append(sample)
        let cutoff = sample.timestamp - windowSeconds
        while let first = window.first, first.timestamp < cutoff {
            window.removeFirst()
        }

        if let last = lastFiredAt, sample.timestamp - last < cooldownSeconds {
            return nil
        }
        guard window.count >= minSamples else { return nil }

        var minX = window[0].x, maxX = window[0].x
        var minY = window[0].y, maxY = window[0].y
        for s in window {
            if s.x < minX { minX = s.x } else if s.x > maxX { maxX = s.x }
            if s.y < minY { minY = s.y } else if s.y > maxY { maxY = s.y }
        }
        let rangeX = maxX - minX
        let rangeY = maxY - minY
        let principalRange = max(rangeX, rangeY)
        guard principalRange >= minAmplitude, principalRange <= maxAmplitude else { return nil }

        let useX = rangeX >= rangeY
        let reversals = Self.countReversals(
            window: window,
            useX: useX,
            minLegLength: minLegLength
        )
        guard reversals >= minReversals else { return nil }

        // Anchor the emitted timestamp at the gesture's BEGINNING (oldest
        // sample currently in the window) rather than its end, so the editor
        // can place the zoom to ramp in across the shake motion. window.first
        // ≈ shake-start within the ingest cadence.
        let gestureStart = window.first?.timestamp ?? sample.timestamp
        lastFiredAt = sample.timestamp
        window.removeAll(keepingCapacity: true)
        return Detection(
            timestamp: gestureStart,
            x: sample.x,
            y: sample.y,
            reversals: reversals
        )
    }

    /// Test seam — exposes window state without making the field public.
    var debugWindowCount: Int { window.count }

    // MARK: - Reversal counter

    fileprivate static func countReversals(
        window: [Sample],
        useX: Bool,
        minLegLength: Double
    ) -> Int {
        guard window.count >= 2 else { return 0 }
        var reversals = 0
        var direction: Int = 0
        var candidate: Double = useX ? window[0].x : window[0].y
        for i in 1..<window.count {
            let v = useX ? window[i].x : window[i].y
            if direction == 0 {
                if v > candidate { direction = 1; candidate = v }
                else if v < candidate { direction = -1; candidate = v }
                continue
            }
            if direction == 1 {
                if v >= candidate {
                    candidate = v
                } else if candidate - v >= minLegLength {
                    reversals += 1
                    candidate = v
                    direction = -1
                }
            } else {
                if v <= candidate {
                    candidate = v
                } else if v - candidate >= minLegLength {
                    reversals += 1
                    candidate = v
                    direction = 1
                }
            }
        }
        return reversals
    }
}
