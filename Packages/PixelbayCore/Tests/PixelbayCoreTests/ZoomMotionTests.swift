import CoreGraphics
import XCTest
@testable import PixelbayCore

final class ZoomMotionTests: XCTestCase {
    func test_interpolateCursorAt_clampsBoundariesAndInterpolatesMidpoint() {
        let telemetry = [
            CursorTelemetryPoint(timeMs: 100, cx: 0.2, cy: 0.4),
            CursorTelemetryPoint(timeMs: 300, cx: 0.8, cy: 0.6)
        ]

        XCTAssertEqual(CursorFollow.interpolateCursorAt(telemetry, timeMs: 0), ZoomFocus(cx: 0.2, cy: 0.4))
        XCTAssertEqual(CursorFollow.interpolateCursorAt(telemetry, timeMs: 500), ZoomFocus(cx: 0.8, cy: 0.6))

        let midpoint = CursorFollow.interpolateCursorAt(telemetry, timeMs: 200)
        XCTAssertEqual(midpoint?.cx ?? -1, 0.5, accuracy: 1e-12)
        XCTAssertEqual(midpoint?.cy ?? -1, 0.5, accuracy: 1e-12)
    }

    func test_advanceFollowFocus_isFrameRateIndependentWhenBaseFactorIsConstant() {
        let params = FollowParams(
            minFactor: 0.1,
            maxFactor: 0.1,
            rampDistance: ZoomMotionConstants.autoFollowRampDistance,
            referenceMs: ZoomMotionConstants.autoFollowReferenceMs
        )
        let start = ZoomFocus(cx: 0, cy: 0)
        let target = ZoomFocus(cx: 1, cy: 0)
        let once = CursorFollow.advanceFollowFocus(
            previous: start,
            raw: target,
            dtMs: 100,
            params: params
        )

        var chunked = start
        for _ in 0..<4 {
            chunked = CursorFollow.advanceFollowFocus(
                previous: chunked,
                raw: target,
                dtMs: 25,
                params: params
            )
        }

        XCTAssertEqual(chunked.cx, once.cx, accuracy: 1e-12)
        XCTAssertEqual(chunked.cy, once.cy, accuracy: 1e-12)
    }

    func test_zoomSpring_doesNotOvershootWhenTargetReverses() {
        let dt = 1000.0 / 60.0
        var state = ZoomSpring.createZoomSpringState()
        ZoomSpring.resetZoomSpring(
            state: &state,
            target: AppliedZoomTransform(scale: 1, x: 0, y: 0)
        )

        for _ in 0..<8 {
            _ = ZoomSpring.stepZoomSpring(
                state: &state,
                target: AppliedZoomTransform(scale: 3, x: 0, y: 0),
                deltaMs: dt
            )
        }

        let reversed = AppliedZoomTransform(scale: 1.5, x: 0, y: 0)
        var minScale = Double.greatestFiniteMagnitude
        for _ in 0..<200 {
            let out = ZoomSpring.stepZoomSpring(state: &state, target: reversed, deltaMs: dt)
            minScale = min(minScale, out.scale)
        }

        XCTAssertGreaterThanOrEqual(minScale, 1.5 - 1e-6)
    }

    func test_computeZoomTransform_mapsFocusToCameraTransform() {
        let transform = ZoomTransformMath.computeZoomTransform(
            stageSize: CGSize(width: 1000, height: 500),
            zoomScale: 2,
            zoomProgress: 1,
            focus: ZoomFocus(cx: 0.25, cy: 0.5)
        )
        XCTAssertEqual(transform.scale, 2, accuracy: 1e-12)
        XCTAssertEqual(transform.x, 0, accuracy: 1e-12)
        XCTAssertEqual(transform.y, -250, accuracy: 1e-12)
    }

    func test_dwellDetectorBuildsRankedNonOverlappingSuggestions() {
        let samples = [
            CursorTelemetryPoint(timeMs: 0, cx: 0.1, cy: 0.1),
            CursorTelemetryPoint(timeMs: 500, cx: 0.105, cy: 0.1),
            CursorTelemetryPoint(timeMs: 1000, cx: 0.7, cy: 0.7),
            CursorTelemetryPoint(timeMs: 1700, cx: 0.705, cy: 0.705)
        ]

        let suggestions = AutoZoomDwellDetector.buildAutoZoomSuggestions(
            cursorTelemetry: samples,
            totalMs: 3000,
            existingRegions: [],
            defaultDurationMs: 1000
        )

        XCTAssertEqual(suggestions.count, 1)
        XCTAssertEqual(suggestions[0].focus.cx, 0.7025, accuracy: 1e-12)
        XCTAssertEqual(suggestions[0].focus.cy, 0.7025, accuracy: 1e-12)
    }
}

