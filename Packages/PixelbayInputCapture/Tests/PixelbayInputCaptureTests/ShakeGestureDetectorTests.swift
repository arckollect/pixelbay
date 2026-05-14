import Foundation
@testable import PixelbayInputCapture
import XCTest

final class ShakeGestureDetectorTests: XCTestCase {
    // MARK: - Happy path

    func test_detector_emitsDetection_onHorizontalWiggle() {
        var detector = ShakeGestureDetector()
        let detection = drive(
            &detector,
            samples: wiggleSamples(
                centerX: 0.5,
                centerY: 0.5,
                amplitude: 0.04,
                axis: .horizontal,
                reversals: 5,
                samplesPerLeg: 3,
                startTime: 1.0,
                legDuration: 0.06
            )
        )
        let fired = try? XCTUnwrap(detection)
        XCTAssertNotNil(fired)
        if let fired {
            XCTAssertGreaterThanOrEqual(fired.reversals, 4)
        }
    }

    func test_detector_emitsDetection_onVerticalWiggle() {
        var detector = ShakeGestureDetector()
        let detection = drive(
            &detector,
            samples: wiggleSamples(
                centerX: 0.5,
                centerY: 0.5,
                amplitude: 0.04,
                axis: .vertical,
                reversals: 5,
                samplesPerLeg: 3,
                startTime: 1.0,
                legDuration: 0.06
            )
        )
        XCTAssertNotNil(detection)
    }

    // MARK: - Negative cases

    func test_detector_doesNotEmit_onLinearMotion() {
        var detector = ShakeGestureDetector()
        // 12 samples on a straight horizontal line — zero reversals.
        let samples = (0..<12).map { i in
            ShakeGestureDetector.Sample(
                timestamp: 1.0 + Double(i) * 0.04,
                x: 0.1 + Double(i) * 0.04,
                y: 0.5
            )
        }
        XCTAssertNil(drive(&detector, samples: samples))
    }

    func test_detector_doesNotEmit_onSingleReversal() {
        // Back-and-forth ONCE (1 reversal) — below the default 4 threshold.
        var detector = ShakeGestureDetector()
        let samples = wiggleSamples(
            centerX: 0.5,
            centerY: 0.5,
            amplitude: 0.05,
            axis: .horizontal,
            reversals: 1,
            samplesPerLeg: 4,
            startTime: 1.0,
            legDuration: 0.08
        )
        XCTAssertNil(drive(&detector, samples: samples))
    }

    func test_detector_doesNotEmit_onTwoReversals() {
        // 2 reversals — still below the default 4.
        var detector = ShakeGestureDetector()
        let samples = wiggleSamples(
            centerX: 0.5,
            centerY: 0.5,
            amplitude: 0.05,
            axis: .horizontal,
            reversals: 2,
            samplesPerLeg: 4,
            startTime: 1.0,
            legDuration: 0.06
        )
        XCTAssertNil(drive(&detector, samples: samples))
    }

    func test_detector_doesNotEmit_whenAmplitudeBelowMin() {
        // Tiny jitter at 0.01 norm-units — below default minAmplitude 0.04.
        var detector = ShakeGestureDetector()
        let samples = wiggleSamples(
            centerX: 0.5,
            centerY: 0.5,
            amplitude: 0.01,
            axis: .horizontal,
            reversals: 6,
            samplesPerLeg: 3,
            startTime: 1.0,
            legDuration: 0.05
        )
        XCTAssertNil(drive(&detector, samples: samples))
    }

    func test_detector_doesNotEmit_whenAmplitudeAboveMax() {
        // 0.30 amplitude — above default maxAmplitude 0.25; looks like
        // "user is dragging the cursor across the screen", not a shake.
        var detector = ShakeGestureDetector()
        let samples = wiggleSamples(
            centerX: 0.5,
            centerY: 0.5,
            amplitude: 0.30,
            axis: .horizontal,
            reversals: 5,
            samplesPerLeg: 3,
            startTime: 1.0,
            legDuration: 0.06
        )
        XCTAssertNil(drive(&detector, samples: samples))
    }

    func test_detector_doesNotEmit_whenBelowMinSamples() {
        // Default minSamples = 8. Drive 5 samples and assert nil.
        var detector = ShakeGestureDetector()
        let samples = (0..<5).map { i in
            ShakeGestureDetector.Sample(
                timestamp: 1.0 + Double(i) * 0.03,
                x: 0.5 + (i.isMultiple(of: 2) ? 0.04 : -0.04),
                y: 0.5
            )
        }
        XCTAssertNil(drive(&detector, samples: samples))
    }

    // MARK: - Cooldown

    func test_detector_appliesCooldown_afterFirstFire() {
        var detector = ShakeGestureDetector(cooldownSeconds: 1.0)
        let first = drive(
            &detector,
            samples: wiggleSamples(
                centerX: 0.5,
                centerY: 0.5,
                amplitude: 0.05,
                axis: .horizontal,
                reversals: 5,
                samplesPerLeg: 3,
                startTime: 1.0,
                legDuration: 0.06
            )
        )
        XCTAssertNotNil(first)

        // Second shake starting 0.1s after the first wiggle's last sample
        // (~1.36s) — comfortably inside the 1.0s cooldown.
        let second = drive(
            &detector,
            samples: wiggleSamples(
                centerX: 0.7,
                centerY: 0.7,
                amplitude: 0.05,
                axis: .horizontal,
                reversals: 5,
                samplesPerLeg: 3,
                startTime: 1.5,
                legDuration: 0.06
            )
        )
        XCTAssertNil(second)
    }

    func test_detector_recoversAfterCooldown() {
        var detector = ShakeGestureDetector(cooldownSeconds: 0.5)
        let first = drive(
            &detector,
            samples: wiggleSamples(
                centerX: 0.3,
                centerY: 0.3,
                amplitude: 0.05,
                axis: .horizontal,
                reversals: 5,
                samplesPerLeg: 3,
                startTime: 1.0,
                legDuration: 0.06
            )
        )
        XCTAssertNotNil(first)
        let second = drive(
            &detector,
            samples: wiggleSamples(
                centerX: 0.7,
                centerY: 0.7,
                amplitude: 0.05,
                axis: .horizontal,
                reversals: 5,
                samplesPerLeg: 3,
                startTime: 4.0,
                legDuration: 0.06
            )
        )
        XCTAssertNotNil(second)
    }

    // MARK: - Sliding window

    func test_detector_doesNotConflateOldSamplesIntoNewGesture() {
        // 200ms of slow drift, large gap so all drift samples slide out
        // of the 0.4s window, then a clean shake.
        var detector = ShakeGestureDetector(cooldownSeconds: 0.0)
        for i in 0..<6 {
            _ = detector.ingest(
                ShakeGestureDetector.Sample(
                    timestamp: 1.0 + Double(i) * 0.03,
                    x: 0.1 + Double(i) * 0.02,
                    y: 0.9
                )
            )
        }
        let detection = drive(
            &detector,
            samples: wiggleSamples(
                centerX: 0.5,
                centerY: 0.5,
                amplitude: 0.05,
                axis: .horizontal,
                reversals: 5,
                samplesPerLeg: 3,
                startTime: 2.5,
                legDuration: 0.06
            )
        )
        XCTAssertNotNil(detection)
    }

    // MARK: - ClickLogger integration

    func test_logger_emitsMarkOnShakeGesture_inMovesPath() async throws {
        let driver = FakeShakeMoveDriver()
        let logger = ClickLogger(
            source: driver.source,
            moveDecimationInterval: 0.0,
            displayPointsBounds: CGRect(x: 0, y: 0, width: 1000, height: 1000),
            gestureDetector: nil,
            shakeDetector: ShakeGestureDetector()
        )
        try await logger.start()

        // Trace a horizontal shake in raw global-points space (centerX=500,
        // amplitude=50 → 0.05 normalised). 5 reversals × 3 samples/leg = 18
        // samples covering ~360ms — inside the 400ms window.
        let samples = wiggleSamples(
            centerX: 500,
            centerY: 500,
            amplitude: 50,
            axis: .horizontal,
            reversals: 5,
            samplesPerLeg: 3,
            startTime: 1.0,
            legDuration: 0.06
        )
        for s in samples {
            driver.fireMove(.init(timestamp: s.timestamp, x: s.x, y: s.y))
        }
        try await Task.sleep(nanoseconds: 200_000_000)

        let recording = await logger.stop()
        XCTAssertEqual(recording.marks.count, 1)
    }

    func test_logger_doesNotEmitMark_whenShakeDetectorNil() async throws {
        let driver = FakeShakeMoveDriver()
        let logger = ClickLogger(
            source: driver.source,
            moveDecimationInterval: 0.0,
            displayPointsBounds: CGRect(x: 0, y: 0, width: 1000, height: 1000),
            gestureDetector: nil,
            shakeDetector: nil
        )
        try await logger.start()

        let samples = wiggleSamples(
            centerX: 500,
            centerY: 500,
            amplitude: 50,
            axis: .horizontal,
            reversals: 5,
            samplesPerLeg: 3,
            startTime: 1.0,
            legDuration: 0.06
        )
        for s in samples {
            driver.fireMove(.init(timestamp: s.timestamp, x: s.x, y: s.y))
        }
        try await Task.sleep(nanoseconds: 200_000_000)

        let recording = await logger.stop()
        XCTAssertEqual(recording.marks, [])
    }

    // MARK: - Helpers

    private enum Axis { case horizontal, vertical }

    private func drive(
        _ detector: inout ShakeGestureDetector,
        samples: [ShakeGestureDetector.Sample]
    ) -> ShakeGestureDetector.Detection? {
        for sample in samples {
            if let detection = detector.ingest(sample) {
                return detection
            }
        }
        return nil
    }

    /// Build a back-and-forth path on a single axis. `reversals` counts the
    /// number of direction changes after the first leg — i.e. the path
    /// `→ ← → ← →` has 4 reversals (5 legs total). `amplitude` is the
    /// peak-to-centre offset, so peak-to-peak range is `2 * amplitude`.
    /// `samplesPerLeg` is the number of samples along one leg, INCLUDING
    /// the endpoint (so the full path has `reversals * samplesPerLeg + 1`
    /// samples).
    private func wiggleSamples(
        centerX: Double,
        centerY: Double,
        amplitude: Double,
        axis: Axis,
        reversals: Int,
        samplesPerLeg: Int,
        startTime: Double,
        legDuration: Double
    ) -> [ShakeGestureDetector.Sample] {
        var samples: [ShakeGestureDetector.Sample] = []
        let totalLegs = reversals + 1
        // Endpoints alternate: +amp, -amp, +amp, -amp, ...
        // First sample sits at the centre, then walks toward the first peak.
        let legCount = max(samplesPerLeg, 2)
        let dt = legDuration / Double(legCount)
        var t = startTime
        // Start at the negative-peak so the first leg moves to +amp, then
        // back to -amp, etc. — clean reversal pattern.
        var currentValue = -amplitude
        samples.append(makeSample(centerX: centerX, centerY: centerY, axis: axis, value: currentValue, timestamp: t))
        for leg in 0..<totalLegs {
            let target = (leg.isMultiple(of: 2)) ? amplitude : -amplitude
            for step in 1...legCount {
                let frac = Double(step) / Double(legCount)
                let v = currentValue + (target - currentValue) * frac
                t += dt
                samples.append(makeSample(centerX: centerX, centerY: centerY, axis: axis, value: v, timestamp: t))
            }
            currentValue = target
        }
        return samples
    }

    private func makeSample(
        centerX: Double,
        centerY: Double,
        axis: Axis,
        value: Double,
        timestamp: Double
    ) -> ShakeGestureDetector.Sample {
        switch axis {
        case .horizontal:
            return .init(timestamp: timestamp, x: centerX + value, y: centerY)
        case .vertical:
            return .init(timestamp: timestamp, x: centerX, y: centerY + value)
        }
    }
}

// Move-only test double — clicks aren't exercised here.
private final class FakeShakeMoveDriver: @unchecked Sendable {
    private let lock = NSLock()
    private var moveSink: (@Sendable (MouseMove) -> Void)?

    var source: ClickEventSource {
        ClickEventSource(
            start: { [weak self] _, onMove in
                self?.lock.lock()
                self?.moveSink = onMove
                self?.lock.unlock()
            },
            stop: { [weak self] in
                self?.lock.lock()
                self?.moveSink = nil
                self?.lock.unlock()
            }
        )
    }

    func fireMove(_ move: MouseMove) {
        lock.lock()
        let sink = moveSink
        lock.unlock()
        sink?(move)
    }
}
