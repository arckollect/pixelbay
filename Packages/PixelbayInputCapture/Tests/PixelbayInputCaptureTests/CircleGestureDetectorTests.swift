import Foundation
@testable import PixelbayInputCapture
import XCTest

final class CircleGestureDetectorTests: XCTestCase {
    // MARK: - Happy path

    func test_detector_emitsDetection_onFullCircle() {
        var detector = CircleGestureDetector()
        let detection = drive(
            &detector,
            samples: circleSamples(
                cx: 0.5,
                cy: 0.5,
                radius: 0.05,
                startAngle: 0,
                sweepRadians: 2 * .pi,
                count: 12,
                duration: 0.4,
                startTime: 1.0
            )
        )
        let fired = try? XCTUnwrap(detection)
        XCTAssertNotNil(fired)
        if let fired {
            XCTAssertEqual(fired.x, 0.5, accuracy: 0.002)
            XCTAssertEqual(fired.y, 0.5, accuracy: 0.002)
            XCTAssertEqual(fired.radius, 0.05, accuracy: 0.002)
        }
    }

    func test_detector_emitsDetection_onCircleNearScreenEdge() {
        // Cursor circle drawn near top-left corner of the screen — coords
        // get close to 0 but the fit must still succeed.
        var detector = CircleGestureDetector()
        let detection = drive(
            &detector,
            samples: circleSamples(
                cx: 0.08,
                cy: 0.08,
                radius: 0.04,
                startAngle: 0,
                sweepRadians: 2 * .pi,
                count: 14,
                duration: 0.45,
                startTime: 0.5
            )
        )
        XCTAssertNotNil(detection)
        if let detection {
            XCTAssertEqual(detection.x, 0.08, accuracy: 0.003)
            XCTAssertEqual(detection.y, 0.08, accuracy: 0.003)
        }
    }

    // MARK: - Negative cases

    func test_detector_doesNotEmit_onLinearMotion() {
        var detector = CircleGestureDetector()
        // 12 samples on a straight horizontal line crossing the screen.
        let samples = (0..<12).map { i in
            CircleGestureDetector.Sample(
                timestamp: 1.0 + Double(i) * 0.04,
                x: 0.1 + Double(i) * 0.04,
                y: 0.5
            )
        }
        XCTAssertNil(drive(&detector, samples: samples))
    }

    func test_detector_doesNotEmit_onPartialArc() {
        // 180° sweep — below the 270° gate.
        var detector = CircleGestureDetector()
        let detection = drive(
            &detector,
            samples: circleSamples(
                cx: 0.5,
                cy: 0.5,
                radius: 0.05,
                startAngle: 0,
                sweepRadians: .pi,
                count: 10,
                duration: 0.4,
                startTime: 1.0
            )
        )
        XCTAssertNil(detection)
    }

    func test_detector_doesNotEmit_whenRadiusBelowMin() {
        // Tiny jitter — radius 0.005 is below the default minRadius 0.015.
        var detector = CircleGestureDetector()
        let detection = drive(
            &detector,
            samples: circleSamples(
                cx: 0.5,
                cy: 0.5,
                radius: 0.005,
                startAngle: 0,
                sweepRadians: 2 * .pi,
                count: 12,
                duration: 0.4,
                startTime: 1.0
            )
        )
        XCTAssertNil(detection)
    }

    func test_detector_doesNotEmit_whenRadiusAboveMax() {
        // 0.20 norm-units is well above default maxRadius 0.10 — looks like
        // "I was just moving the cursor across the screen" not a gesture.
        var detector = CircleGestureDetector()
        let detection = drive(
            &detector,
            samples: circleSamples(
                cx: 0.5,
                cy: 0.5,
                radius: 0.20,
                startAngle: 0,
                sweepRadians: 2 * .pi,
                count: 14,
                duration: 0.45,
                startTime: 1.0
            )
        )
        XCTAssertNil(detection)
    }

    func test_detector_doesNotEmit_whenBelowMinSamples() {
        // Default minSamples = 6. Drive only 4 samples and assert nil.
        var detector = CircleGestureDetector()
        let samples = circleSamples(
            cx: 0.5,
            cy: 0.5,
            radius: 0.05,
            startAngle: 0,
            sweepRadians: 2 * .pi,
            count: 4,
            duration: 0.15,
            startTime: 1.0
        )
        XCTAssertNil(drive(&detector, samples: samples))
    }

    // MARK: - Cooldown

    func test_detector_appliesCooldown_afterFirstFire() {
        var detector = CircleGestureDetector(cooldownSeconds: 1.0)
        let first = drive(
            &detector,
            samples: circleSamples(
                cx: 0.5, cy: 0.5, radius: 0.05,
                startAngle: 0, sweepRadians: 2 * .pi,
                count: 12, duration: 0.4, startTime: 1.0
            )
        )
        XCTAssertNotNil(first)

        // Second circle 0.3s after the first fires — inside cooldown.
        let second = drive(
            &detector,
            samples: circleSamples(
                cx: 0.7, cy: 0.7, radius: 0.05,
                startAngle: 0, sweepRadians: 2 * .pi,
                count: 12, duration: 0.4, startTime: 1.7
            )
        )
        XCTAssertNil(second)
    }

    func test_detector_recoversAfterCooldown() {
        var detector = CircleGestureDetector(cooldownSeconds: 0.5)
        let first = drive(
            &detector,
            samples: circleSamples(
                cx: 0.3, cy: 0.3, radius: 0.04,
                startAngle: 0, sweepRadians: 2 * .pi,
                count: 12, duration: 0.4, startTime: 1.0
            )
        )
        XCTAssertNotNil(first)
        // Wait past cooldown, then run another gesture.
        let second = drive(
            &detector,
            samples: circleSamples(
                cx: 0.7, cy: 0.7, radius: 0.04,
                startAngle: 0, sweepRadians: 2 * .pi,
                count: 12, duration: 0.4, startTime: 3.0
            )
        )
        XCTAssertNotNil(second)
        if let second {
            XCTAssertEqual(second.x, 0.7, accuracy: 0.003)
            XCTAssertEqual(second.y, 0.7, accuracy: 0.003)
        }
    }

    // MARK: - Sliding window

    func test_detector_doesNotConflateOldSamplesIntoNewGesture() {
        // 200ms of linear motion, then 0.5s gap (older samples drop out),
        // then a fresh circle. The linear samples must NOT pollute the fit.
        var detector = CircleGestureDetector(cooldownSeconds: 0.0)
        for i in 0..<6 {
            _ = detector.ingest(
                CircleGestureDetector.Sample(
                    timestamp: 1.0 + Double(i) * 0.03,
                    x: 0.1 + Double(i) * 0.02,
                    y: 0.9
                )
            )
        }
        // Gap large enough that all linear samples slide out of the 0.5s
        // window before the new gesture begins.
        let detection = drive(
            &detector,
            samples: circleSamples(
                cx: 0.5, cy: 0.5, radius: 0.05,
                startAngle: 0, sweepRadians: 2 * .pi,
                count: 12, duration: 0.4, startTime: 2.0
            )
        )
        XCTAssertNotNil(detection)
        if let detection {
            XCTAssertEqual(detection.x, 0.5, accuracy: 0.003)
            XCTAssertEqual(detection.y, 0.5, accuracy: 0.003)
        }
    }

    // MARK: - ClickLogger integration

    func test_logger_emitsMarkOnCircleGesture_inMovesPath() async throws {
        let driver = FakeMoveDriver()
        let logger = ClickLogger(
            source: driver.source,
            moveDecimationInterval: 0.0,
            displayPointsBounds: CGRect(x: 0, y: 0, width: 1000, height: 1000),
            gestureDetector: CircleGestureDetector()
        )
        try await logger.start()

        // Trace a circle in raw global-points space (cx=500, cy=500, r=50).
        // displayPointsBounds = 1000×1000 normalises these to (0.5, 0.5, 0.05).
        let count = 14
        for i in 0..<count {
            let angle = Double(i) / Double(count) * 2 * .pi
            let x = 500 + 50 * cos(angle)
            let y = 500 + 50 * sin(angle)
            driver.fireMove(.init(
                timestamp: 1.0 + Double(i) * 0.03,
                x: x,
                y: y
            ))
        }

        // Drain async actor work.
        try await Task.sleep(nanoseconds: 200_000_000)

        let recording = await logger.stop()
        XCTAssertEqual(recording.marks.count, 1)
        if let mark = recording.marks.first {
            XCTAssertEqual(mark.x, 0.5, accuracy: 0.01)
            XCTAssertEqual(mark.y, 0.5, accuracy: 0.01)
        }
    }

    func test_logger_doesNotEmitMark_whenGestureDetectorNil() async throws {
        let driver = FakeMoveDriver()
        let logger = ClickLogger(
            source: driver.source,
            moveDecimationInterval: 0.0,
            displayPointsBounds: CGRect(x: 0, y: 0, width: 1000, height: 1000),
            gestureDetector: nil
        )
        try await logger.start()

        // Same circle as the previous test — should NOT emit a mark.
        let count = 14
        for i in 0..<count {
            let angle = Double(i) / Double(count) * 2 * .pi
            driver.fireMove(.init(
                timestamp: 1.0 + Double(i) * 0.03,
                x: 500 + 50 * cos(angle),
                y: 500 + 50 * sin(angle)
            ))
        }
        try await Task.sleep(nanoseconds: 200_000_000)

        let recording = await logger.stop()
        XCTAssertEqual(recording.marks, [])
    }

    // MARK: - Helpers

    /// Drive the detector with a series of samples. Returns the FIRST
    /// detection emitted (and stops driving subsequent samples after that —
    /// the caller's `samples` array typically contains exactly one full
    /// gesture's worth of points, so the first detection is the only one
    /// we care about).
    private func drive(
        _ detector: inout CircleGestureDetector,
        samples: [CircleGestureDetector.Sample]
    ) -> CircleGestureDetector.Detection? {
        for sample in samples {
            if let detection = detector.ingest(sample) {
                return detection
            }
        }
        return nil
    }

    private func circleSamples(
        cx: Double,
        cy: Double,
        radius: Double,
        startAngle: Double,
        sweepRadians: Double,
        count: Int,
        duration: Double,
        startTime: Double
    ) -> [CircleGestureDetector.Sample] {
        guard count > 1 else { return [] }
        let dt = duration / Double(count - 1)
        let dAngle = sweepRadians / Double(count - 1)
        return (0..<count).map { i in
            let angle = startAngle + Double(i) * dAngle
            return CircleGestureDetector.Sample(
                timestamp: startTime + Double(i) * dt,
                x: cx + radius * cos(angle),
                y: cy + radius * sin(angle)
            )
        }
    }
}

// Move-only test double — clicks aren't exercised here, so the click sink
// is a no-op.
private final class FakeMoveDriver: @unchecked Sendable {
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
