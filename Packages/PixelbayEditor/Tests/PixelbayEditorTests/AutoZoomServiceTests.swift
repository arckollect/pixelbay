import CoreGraphics
import Foundation
import PixelbayCore
import PixelbayInputCapture
@testable import PixelbayEditor
import XCTest

final class AutoZoomServiceTests: XCTestCase {

    // MARK: - sessionID(fromScreenRelativePath:)

    func test_sessionID_extractsFromStandardPath() {
        XCTAssertEqual(
            AutoZoomService.sessionID(fromScreenRelativePath: "media/screen-a1b2c3d4.mov"),
            "a1b2c3d4"
        )
    }

    func test_sessionID_extractsFromBareBasename() {
        XCTAssertEqual(
            AutoZoomService.sessionID(fromScreenRelativePath: "screen-abcd1234.mov"),
            "abcd1234"
        )
    }

    func test_sessionID_returnsNilForNonScreenPath() {
        XCTAssertNil(AutoZoomService.sessionID(fromScreenRelativePath: "media/cam-a1b2c3d4.mov"))
        XCTAssertNil(AutoZoomService.sessionID(fromScreenRelativePath: "media/sysaudio-a1b2c3d4.caf"))
    }

    func test_sessionID_returnsNilWhenMissingExtension() {
        XCTAssertNil(AutoZoomService.sessionID(fromScreenRelativePath: "media/screen-a1b2c3d4"))
    }

    func test_sessionID_returnsNilForEmptyID() {
        XCTAssertNil(AutoZoomService.sessionID(fromScreenRelativePath: "media/screen-.mov"))
    }

    // MARK: - clicksSidecarURL(forScreenAsset:in:)

    func test_clicksSidecarURL_buildsExpectedPath() {
        let bundle = URL(fileURLWithPath: "/tmp/proj.pixelbay", isDirectory: true)
        let asset = MediaAsset(
            kind: .display,
            relativePath: "media/screen-a1b2c3d4.mov",
            nativeDuration: RationalTime(value: 600, timescale: 600)
        )
        let url = AutoZoomService.clicksSidecarURL(forScreenAsset: asset, in: bundle)
        XCTAssertEqual(url?.path, "/tmp/proj.pixelbay/media/clicks-a1b2c3d4.json")
    }

    func test_clicksSidecarURL_returnsNilForNonDisplayAsset() {
        let bundle = URL(fileURLWithPath: "/tmp/proj.pixelbay", isDirectory: true)
        let cam = MediaAsset(
            kind: .webcam,
            relativePath: "media/cam-a1b2c3d4.mov",
            nativeDuration: RationalTime(value: 600, timescale: 600)
        )
        XCTAssertNil(AutoZoomService.clicksSidecarURL(forScreenAsset: cam, in: bundle))
    }

    func test_clicksSidecarURL_returnsNilWhenPathUnparseable() {
        let bundle = URL(fileURLWithPath: "/tmp/proj.pixelbay", isDirectory: true)
        let asset = MediaAsset(
            kind: .display,
            relativePath: "media/weird-name.mov",
            nativeDuration: RationalTime(value: 600, timescale: 600)
        )
        XCTAssertNil(AutoZoomService.clicksSidecarURL(forScreenAsset: asset, in: bundle))
    }

    // MARK: - screenAsset(in:)

    func test_screenAsset_returnsFirstDisplayKind() {
        let display = MediaAsset(
            kind: .display,
            relativePath: "media/screen-aaaa1111.mov",
            nativeDuration: RationalTime(value: 600, timescale: 600)
        )
        let cam = MediaAsset(
            kind: .webcam,
            relativePath: "media/cam-aaaa1111.mov",
            nativeDuration: RationalTime(value: 600, timescale: 600)
        )
        var project = Project(name: "P")
        project.assets = [cam, display]
        XCTAssertEqual(AutoZoomService.screenAsset(in: project)?.id, display.id)
    }

    func test_screenAsset_returnsNilWhenNoDisplay() {
        var project = Project(name: "P")
        project.assets = [
            MediaAsset(
                kind: .webcam,
                relativePath: "media/cam-1.mov",
                nativeDuration: RationalTime(value: 600, timescale: 600)
            )
        ]
        XCTAssertNil(AutoZoomService.screenAsset(in: project))
    }

    // MARK: - autoZoomClicks(from:screenPixelSize:)

    /// Build a legacy (v2) sidecar — x/y stored as raw global points; the
    /// editor divides by `screenPixelSize` to normalise. The bulk of the
    /// tests below cover that legacy path. The v3-skip-division path is
    /// covered by the dedicated `*_v3_*` tests at the end of each section.
    private func makeSidecar(captureStart: Double, events: [ClickEvent]) -> ClicksSidecar {
        ClicksSidecar(version: 2, sessionID: "test1234", captureStart: captureStart, events: events)
    }

    func test_clicks_subtractsCaptureStartForTimelineTime() {
        let sidecar = makeSidecar(
            captureStart: 1000.0,
            events: [
                ClickEvent(timestamp: 1001.5, x: 0, y: 0, button: .left),
                ClickEvent(timestamp: 1003.25, x: 0, y: 0, button: .left)
            ]
        )
        let clicks = AutoZoomService.autoZoomClicks(
            from: sidecar,
            screenPixelSize: CGSize(width: 1920, height: 1080)
        )
        XCTAssertEqual(clicks.count, 2)
        XCTAssertEqual(clicks[0].timelineTime, 1.5, accuracy: 0.0001)
        XCTAssertEqual(clicks[1].timelineTime, 3.25, accuracy: 0.0001)
    }

    func test_clicks_dropsEventsBeforeCaptureStart() {
        let sidecar = makeSidecar(
            captureStart: 1000.0,
            events: [
                ClickEvent(timestamp: 999.9, x: 0, y: 0, button: .left),
                ClickEvent(timestamp: 1000.5, x: 0, y: 0, button: .left)
            ]
        )
        let clicks = AutoZoomService.autoZoomClicks(
            from: sidecar,
            screenPixelSize: CGSize(width: 1920, height: 1080)
        )
        XCTAssertEqual(clicks.count, 1)
        XCTAssertEqual(clicks[0].timelineTime, 0.5, accuracy: 0.0001)
    }

    func test_clicks_filtersRightButtonByDefault() {
        let sidecar = makeSidecar(
            captureStart: 0.0,
            events: [
                ClickEvent(timestamp: 1.0, x: 0, y: 0, button: .left),
                ClickEvent(timestamp: 2.0, x: 0, y: 0, button: .right)
            ]
        )
        let clicks = AutoZoomService.autoZoomClicks(
            from: sidecar,
            screenPixelSize: CGSize(width: 1920, height: 1080)
        )
        XCTAssertEqual(clicks.count, 1)
        XCTAssertEqual(clicks[0].timelineTime, 1.0, accuracy: 0.0001)
    }

    func test_clicks_includesRightButtonWhenOptedIn() {
        let sidecar = makeSidecar(
            captureStart: 0.0,
            events: [
                ClickEvent(timestamp: 1.0, x: 0, y: 0, button: .left),
                ClickEvent(timestamp: 2.0, x: 0, y: 0, button: .right)
            ]
        )
        let clicks = AutoZoomService.autoZoomClicks(
            from: sidecar,
            screenPixelSize: CGSize(width: 1920, height: 1080),
            leftButtonOnly: false
        )
        XCTAssertEqual(clicks.count, 2)
    }

    func test_clicks_normalisesXYAgainstScreenPixelSize() {
        let sidecar = makeSidecar(
            captureStart: 0.0,
            events: [
                ClickEvent(timestamp: 1.0, x: 960, y: 540, button: .left)
            ]
        )
        let clicks = AutoZoomService.autoZoomClicks(
            from: sidecar,
            screenPixelSize: CGSize(width: 1920, height: 1080)
        )
        XCTAssertEqual(clicks.count, 1)
        XCTAssertEqual(clicks[0].centerX, 0.5, accuracy: 0.0001)
        XCTAssertEqual(clicks[0].centerY, 0.5, accuracy: 0.0001)
    }

    func test_clicks_clampsOutOfBoundsCoordinates() {
        let sidecar = makeSidecar(
            captureStart: 0.0,
            events: [
                ClickEvent(timestamp: 1.0, x: -100, y: 2000, button: .left),
                ClickEvent(timestamp: 2.0, x: 5000, y: -50, button: .left)
            ]
        )
        let clicks = AutoZoomService.autoZoomClicks(
            from: sidecar,
            screenPixelSize: CGSize(width: 1920, height: 1080)
        )
        XCTAssertEqual(clicks.count, 2)
        XCTAssertEqual(clicks[0].centerX, 0.0, accuracy: 0.0001)
        XCTAssertEqual(clicks[0].centerY, 1.0, accuracy: 0.0001)
        XCTAssertEqual(clicks[1].centerX, 1.0, accuracy: 0.0001)
        XCTAssertEqual(clicks[1].centerY, 0.0, accuracy: 0.0001)
    }

    func test_clicks_defaultsToCenterWhenPixelSizeDegenerate() {
        let sidecar = makeSidecar(
            captureStart: 0.0,
            events: [
                ClickEvent(timestamp: 1.0, x: 999, y: 999, button: .left)
            ]
        )
        let clicks = AutoZoomService.autoZoomClicks(
            from: sidecar,
            screenPixelSize: CGSize(width: 0, height: 0)
        )
        XCTAssertEqual(clicks.count, 1)
        XCTAssertEqual(clicks[0].centerX, 0.5, accuracy: 0.0001)
        XCTAssertEqual(clicks[0].centerY, 0.5, accuracy: 0.0001)
    }

    // MARK: - mouseTrajectory(from:screenPixelSize:)

    private func makeSidecarWithMoves(
        captureStart: Double,
        events: [ClickEvent] = [],
        moves: [MouseMove]
    ) -> ClicksSidecar {
        ClicksSidecar(
            version: 2,
            sessionID: "test1234",
            captureStart: captureStart,
            events: events,
            moves: moves
        )
    }

    func test_trajectory_subtractsCaptureStartForTimelineTime() {
        let sidecar = makeSidecarWithMoves(
            captureStart: 1000.0,
            moves: [
                MouseMove(timestamp: 1000.5, x: 0, y: 0),
                MouseMove(timestamp: 1002.0, x: 0, y: 0)
            ]
        )
        let trajectory = AutoZoomService.mouseTrajectory(
            from: sidecar,
            screenPixelSize: CGSize(width: 1920, height: 1080)
        )
        XCTAssertEqual(trajectory.count, 2)
        XCTAssertEqual(trajectory[0].timelineTime, 0.5, accuracy: 0.0001)
        XCTAssertEqual(trajectory[1].timelineTime, 2.0, accuracy: 0.0001)
    }

    func test_trajectory_dropsSamplesBeforeCaptureStart() {
        let sidecar = makeSidecarWithMoves(
            captureStart: 1000.0,
            moves: [
                MouseMove(timestamp: 999.5, x: 0, y: 0),
                MouseMove(timestamp: 1001.0, x: 0, y: 0)
            ]
        )
        let trajectory = AutoZoomService.mouseTrajectory(
            from: sidecar,
            screenPixelSize: CGSize(width: 1920, height: 1080)
        )
        XCTAssertEqual(trajectory.count, 1)
        XCTAssertEqual(trajectory[0].timelineTime, 1.0, accuracy: 0.0001)
    }

    func test_trajectory_normalisesAndClampsAgainstScreenSize() {
        let sidecar = makeSidecarWithMoves(
            captureStart: 0.0,
            moves: [
                MouseMove(timestamp: 0.5, x: 960, y: 540),
                MouseMove(timestamp: 1.0, x: 5000, y: -50)
            ]
        )
        let trajectory = AutoZoomService.mouseTrajectory(
            from: sidecar,
            screenPixelSize: CGSize(width: 1920, height: 1080)
        )
        XCTAssertEqual(trajectory.count, 2)
        XCTAssertEqual(trajectory[0].centerX, 0.5, accuracy: 0.0001)
        XCTAssertEqual(trajectory[0].centerY, 0.5, accuracy: 0.0001)
        XCTAssertEqual(trajectory[1].centerX, 1.0, accuracy: 0.0001)
        XCTAssertEqual(trajectory[1].centerY, 0.0, accuracy: 0.0001)
    }

    func test_trajectory_degeneratePixelSize_fallsBackToCenter() {
        let sidecar = makeSidecarWithMoves(
            captureStart: 0.0,
            moves: [MouseMove(timestamp: 0.5, x: 999, y: 999)]
        )
        let trajectory = AutoZoomService.mouseTrajectory(
            from: sidecar,
            screenPixelSize: CGSize(width: 0, height: 0)
        )
        XCTAssertEqual(trajectory.count, 1)
        XCTAssertEqual(trajectory[0].centerX, 0.5, accuracy: 0.0001)
        XCTAssertEqual(trajectory[0].centerY, 0.5, accuracy: 0.0001)
    }

    // MARK: - trajectoryWindow(_:timelineRange:)

    func test_trajectoryWindow_emptyMaster_returnsEmpty() {
        let result = AutoZoomService.trajectoryWindow(
            [],
            timelineRange: TimeRange(start: .seconds(1), duration: .seconds(2))
        )
        XCTAssertEqual(result, [])
    }

    func test_trajectoryWindow_slicesSamplesInRange_andRebasesToLocalTime() {
        let master: [MouseTrajectorySample] = [
            MouseTrajectorySample(timelineTime: 0.0, centerX: 0.10, centerY: 0.10),
            MouseTrajectorySample(timelineTime: 1.0, centerX: 0.20, centerY: 0.20),
            MouseTrajectorySample(timelineTime: 2.0, centerX: 0.30, centerY: 0.30),
            MouseTrajectorySample(timelineTime: 3.0, centerX: 0.40, centerY: 0.40),
            MouseTrajectorySample(timelineTime: 4.0, centerX: 0.50, centerY: 0.50)
        ]
        let result = AutoZoomService.trajectoryWindow(
            master,
            timelineRange: TimeRange(start: .seconds(1), duration: .seconds(2))
        )
        // Window [1, 3] inclusive → samples at t=1, t=2, t=3 (rebased to 0, 1, 2).
        XCTAssertEqual(result.count, 3)
        XCTAssertEqual(result[0], ZoomTrajectorySample(t: 0.0, x: 0.20, y: 0.20))
        XCTAssertEqual(result[1], ZoomTrajectorySample(t: 1.0, x: 0.30, y: 0.30))
        XCTAssertEqual(result[2], ZoomTrajectorySample(t: 2.0, x: 0.40, y: 0.40))
    }

    func test_trajectoryWindow_includesSampleAtRangeEdges() {
        let master: [MouseTrajectorySample] = [
            MouseTrajectorySample(timelineTime: 1.0, centerX: 0.1, centerY: 0.1),
            MouseTrajectorySample(timelineTime: 3.0, centerX: 0.9, centerY: 0.9)
        ]
        let result = AutoZoomService.trajectoryWindow(
            master,
            timelineRange: TimeRange(start: .seconds(1), duration: .seconds(2))
        )
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result[0].t, 0.0, accuracy: 1e-9)
        XCTAssertEqual(result[1].t, 2.0, accuracy: 1e-9)
    }

    func test_trajectoryWindow_noSamplesInRange_returnsEmpty() {
        let master: [MouseTrajectorySample] = [
            MouseTrajectorySample(timelineTime: 0.0, centerX: 0, centerY: 0),
            MouseTrajectorySample(timelineTime: 0.5, centerX: 0, centerY: 0),
            MouseTrajectorySample(timelineTime: 10.0, centerX: 0, centerY: 0)
        ]
        let result = AutoZoomService.trajectoryWindow(
            master,
            timelineRange: TimeRange(start: .seconds(2), duration: .seconds(3))
        )
        XCTAssertEqual(result, [])
    }

    func test_trajectoryWindow_degenerateRange_returnsEmpty() {
        let master = [MouseTrajectorySample(timelineTime: 1.0, centerX: 0.5, centerY: 0.5)]
        let result = AutoZoomService.trajectoryWindow(
            master,
            timelineRange: TimeRange(start: .seconds(0), duration: .seconds(0))
        )
        XCTAssertEqual(result, [])
    }

    // MARK: - v3 sidecar coordinate semantics (pre-normalised)

    /// Build a v3 sidecar — x/y are already in `[0…1]` so the service should
    /// pass them through without dividing by `screenPixelSize`.
    private func makeV3Sidecar(captureStart: Double, events: [ClickEvent], moves: [MouseMove] = []) -> ClicksSidecar {
        ClicksSidecar(
            version: 3,
            sessionID: "v3session",
            captureStart: captureStart,
            events: events,
            moves: moves
        )
    }

    func test_clicks_v3SidecarSkipsDivision_andPassesValuesThrough() {
        let sidecar = makeV3Sidecar(
            captureStart: 0,
            events: [
                ClickEvent(timestamp: 1.0, x: 0.25, y: 0.75, button: .left),
                ClickEvent(timestamp: 2.0, x: 0.5, y: 0.5, button: .left)
            ]
        )
        // screenPixelSize is irrelevant for v3 — pass any plausible value to
        // confirm the new branch ignores it.
        let clicks = AutoZoomService.autoZoomClicks(
            from: sidecar,
            screenPixelSize: CGSize(width: 1920, height: 1080)
        )
        XCTAssertEqual(clicks.count, 2)
        XCTAssertEqual(clicks[0].centerX, 0.25, accuracy: 0.0001)
        XCTAssertEqual(clicks[0].centerY, 0.75, accuracy: 0.0001)
        XCTAssertEqual(clicks[1].centerX, 0.5, accuracy: 0.0001)
        XCTAssertEqual(clicks[1].centerY, 0.5, accuracy: 0.0001)
    }

    func test_clicks_v3SidecarClampsOutOfRangeDefensively() {
        // Writers should never emit values outside [0…1] for v3, but if a
        // future writer slips up the service still clamps rather than feed
        // wild values into the keyframe centre.
        let sidecar = makeV3Sidecar(
            captureStart: 0,
            events: [
                ClickEvent(timestamp: 1.0, x: -0.5, y: 1.5, button: .left)
            ]
        )
        let clicks = AutoZoomService.autoZoomClicks(
            from: sidecar,
            screenPixelSize: CGSize(width: 1920, height: 1080)
        )
        XCTAssertEqual(clicks[0].centerX, 0.0, accuracy: 0.0001)
        XCTAssertEqual(clicks[0].centerY, 1.0, accuracy: 0.0001)
    }

    func test_clicks_v3SidecarStillSubtractsCaptureStart() {
        let sidecar = makeV3Sidecar(
            captureStart: 500,
            events: [ClickEvent(timestamp: 502.5, x: 0.3, y: 0.4, button: .left)]
        )
        let clicks = AutoZoomService.autoZoomClicks(
            from: sidecar,
            screenPixelSize: .zero
        )
        XCTAssertEqual(clicks[0].timelineTime, 2.5, accuracy: 0.0001)
        XCTAssertEqual(clicks[0].centerX, 0.3, accuracy: 0.0001)
    }

    func test_trajectory_v3SidecarSkipsDivision_andPassesValuesThrough() {
        let sidecar = makeV3Sidecar(
            captureStart: 0,
            events: [],
            moves: [
                MouseMove(timestamp: 0.5, x: 0.25, y: 0.6),
                MouseMove(timestamp: 1.0, x: 0.9, y: 0.1)
            ]
        )
        let trajectory = AutoZoomService.mouseTrajectory(
            from: sidecar,
            screenPixelSize: CGSize(width: 1920, height: 1080)
        )
        XCTAssertEqual(trajectory.count, 2)
        XCTAssertEqual(trajectory[0].centerX, 0.25, accuracy: 0.0001)
        XCTAssertEqual(trajectory[0].centerY, 0.6, accuracy: 0.0001)
        XCTAssertEqual(trajectory[1].centerX, 0.9, accuracy: 0.0001)
        XCTAssertEqual(trajectory[1].centerY, 0.1, accuracy: 0.0001)
    }

    func test_trajectory_v3SidecarClampsOutOfRangeDefensively() {
        let sidecar = makeV3Sidecar(
            captureStart: 0,
            events: [],
            moves: [MouseMove(timestamp: 0.5, x: -0.1, y: 1.2)]
        )
        let trajectory = AutoZoomService.mouseTrajectory(
            from: sidecar,
            screenPixelSize: .zero
        )
        XCTAssertEqual(trajectory[0].centerX, 0.0, accuracy: 0.0001)
        XCTAssertEqual(trajectory[0].centerY, 1.0, accuracy: 0.0001)
    }

    // MARK: - End-to-end integration with GenerateAutoZoomFromClicksCommand

    func test_endToEnd_serviceOutputFeedsGenerateCommand() throws {
        var (project, _) = EditorFixture.minimalSingleClip()
        XCTAssertTrue(project.effects.isEmpty)

        // Click timestamps are spaced widely (8s gap) so they end up in
        // separate clusters under the auto-zoom merge pre-pass — this test
        // is about pipeline wiring, not merge behavior.
        let sidecar = makeSidecar(
            captureStart: 100.0,
            events: [
                ClickEvent(timestamp: 102.0, x: 960, y: 540, button: .left),
                ClickEvent(timestamp: 110.0, x: 1920, y: 1080, button: .left)
            ]
        )
        let clicks = AutoZoomService.autoZoomClicks(
            from: sidecar,
            screenPixelSize: CGSize(width: 1920, height: 1080)
        )

        let cmd = GenerateAutoZoomFromClicksCommand(clicks: clicks)
        _ = try cmd.apply(to: &project)

        XCTAssertEqual(project.effects.count, 2)
        XCTAssertTrue(project.effects.allSatisfy { $0.kind == .zoom })
    }

    // MARK: - zoomMarks (slice #11.d)

    func test_zoomMarks_v4_convertsTimelineTimeAndNormalisedCoords() {
        let sidecar = ClicksSidecar(
            version: 4,
            sessionID: "marks-1",
            captureStart: 100.0,
            events: [],
            moves: [],
            marks: [
                ZoomMark(timestamp: 102.5, x: 0.6, y: 0.7),
                ZoomMark(timestamp: 105.0, x: 0.2, y: 0.3)
            ]
        )
        let marks = AutoZoomService.zoomMarks(from: sidecar, screenPixelSize: CGSize(width: 1920, height: 1080))
        XCTAssertEqual(marks.count, 2)
        XCTAssertEqual(marks[0].timelineTime, 2.5, accuracy: 1e-9)
        XCTAssertEqual(marks[0].centerX, 0.6, accuracy: 1e-9)
        XCTAssertEqual(marks[1].timelineTime, 5.0, accuracy: 1e-9)
    }

    func test_zoomMarks_emptyForSidecarWithoutMarks() {
        let sidecar = makeSidecar(captureStart: 100, events: [])
        let marks = AutoZoomService.zoomMarks(from: sidecar, screenPixelSize: CGSize(width: 1920, height: 1080))
        XCTAssertEqual(marks, [])
    }

    // Note: dwell-filter and deceleration-trigger test cases were removed in
    // the Phase 3c intent-scoring rewrite. Their replacement coverage lives
    // in `IntentScorerTests.swift`.
}
