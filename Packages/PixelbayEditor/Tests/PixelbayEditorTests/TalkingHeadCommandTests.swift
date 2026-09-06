import XCTest
@testable import PixelbayEditor
import PixelbayCore

// Exercises `AddTalkingHeadAtPlayheadCommand` (EditCommands+TalkingHead.swift).
final class TalkingHeadCommandTests: XCTestCase {

    func test_addTalkingHead_insertsOneKeyframe_withDefaultEnvelope() throws {
        var project = makeScreenAndWebcamProject()
        let command = AddTalkingHeadAtPlayheadCommand(timelineTime: 2.0)
        _ = try command.apply(to: &project)
        XCTAssertEqual(project.effects.count, 1)
        let kf = project.effects[0]
        XCTAssertEqual(kf.kind, .talkingHeadSwap)
        XCTAssertEqual(kf.timelineRange.start.seconds, 2.0, accuracy: 0.001)
        // 0.4 ease-in + 3.0 hold + 0.4 ease-out.
        XCTAssertEqual(kf.timelineRange.duration.seconds, 3.8, accuracy: 0.001)
        XCTAssertEqual(kf.easeIn.seconds, 0.4, accuracy: 0.001)
        XCTAssertEqual(kf.easeOut.seconds, 0.4, accuracy: 0.001)
    }

    func test_addTalkingHead_inverseRemovesKeyframe() throws {
        var project = makeScreenAndWebcamProject()
        let inverse = try AddTalkingHeadAtPlayheadCommand(timelineTime: 1.0).apply(to: &project)
        XCTAssertEqual(project.effects.count, 1)
        _ = try inverse.apply(to: &project)
        XCTAssertTrue(project.effects.isEmpty)
    }

    func test_addTalkingHead_throws_whenNoWebcam() {
        var (project, _) = EditorFixture.minimalSingleClip()   // screen only
        let command = AddTalkingHeadAtPlayheadCommand(timelineTime: 1.0)
        XCTAssertNotNil(command.insertionConflict(in: project))
        XCTAssertThrowsError(try command.apply(to: &project))
        XCTAssertTrue(project.effects.isEmpty)
    }

    func test_addTalkingHead_clampsToTimelineEnd() throws {
        var project = makeScreenAndWebcamProject()   // 8s timeline
        let command = AddTalkingHeadAtPlayheadCommand(timelineTime: 6.0, timelineDuration: 8.0)
        XCTAssertNil(command.insertionConflict(in: project))
        _ = try command.apply(to: &project)
        let range = project.effects[0].timelineRange
        XCTAssertEqual(range.end.seconds, 8.0, accuracy: 0.001, "shortened to end exactly at the timeline end")
        XCTAssertEqual(range.duration.seconds, 2.0, accuracy: 0.001)
    }

    func test_addTalkingHead_throws_whenTooLittleTimelineLeft() {
        var project = makeScreenAndWebcamProject()
        let command = AddTalkingHeadAtPlayheadCommand(timelineTime: 7.8, timelineDuration: 8.0)
        XCTAssertNotNil(command.insertionConflict(in: project))
        XCTAssertThrowsError(try command.apply(to: &project))
    }

    func test_addTalkingHead_throws_whenInsideExistingTalkingHead() throws {
        var project = makeScreenAndWebcamProject()
        _ = try AddTalkingHeadAtPlayheadCommand(timelineTime: 1.0).apply(to: &project)
        let second = AddTalkingHeadAtPlayheadCommand(timelineTime: 2.0)
        XCTAssertNotNil(second.insertionConflict(in: project))
        XCTAssertThrowsError(try second.apply(to: &project))
        XCTAssertEqual(project.effects.count, 1)
    }

    func test_addTalkingHead_mayOverlapAZoom() throws {
        var project = makeScreenAndWebcamProject()
        _ = try AddZoomAtPlayheadCommand(timelineTime: 2.0).apply(to: &project)
        let talkingHead = AddTalkingHeadAtPlayheadCommand(timelineTime: 2.0)
        XCTAssertNil(talkingHead.insertionConflict(in: project), "zoom overlap is allowed")
        _ = try talkingHead.apply(to: &project)
        XCTAssertEqual(project.effects.count, 2)
    }

    func test_addTalkingHead_negativeTimeClampsToZero() throws {
        var project = makeScreenAndWebcamProject()
        _ = try AddTalkingHeadAtPlayheadCommand(timelineTime: -1.0).apply(to: &project)
        XCTAssertEqual(project.effects[0].timelineRange.start.seconds, 0, accuracy: 0.001)
    }

    // MARK: - Fixture

    /// Screen + webcam, both 0..8s on the timeline.
    private func makeScreenAndWebcamProject() -> Project {
        let screen = MediaAsset(kind: .display, relativePath: "media/s.mov",
                                captureStart: nil, nativeDuration: .seconds(8))
        let cam = MediaAsset(kind: .webcam, relativePath: "media/c.mov",
                             captureStart: nil, nativeDuration: .seconds(8))
        let mkClip: (MediaAsset) -> Clip = { asset in
            Clip(
                assetID: asset.id,
                sourceRange: TimeRange(start: .seconds(0), duration: .seconds(8)),
                timelineRange: TimeRange(start: .seconds(0), duration: .seconds(8))
            )
        }
        var project = Project(name: "TalkingHead")
        project.assets = [screen, cam]
        project.tracks = [
            Track(kind: .screen, name: "Screen", clips: [mkClip(screen)]),
            Track(kind: .webcam, name: "Cam", clips: [mkClip(cam)])
        ]
        return project
    }
}
