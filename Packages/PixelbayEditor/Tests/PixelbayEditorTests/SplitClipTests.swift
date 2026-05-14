import PixelbayCore
@testable import PixelbayEditor
import XCTest

final class SplitClipTests: XCTestCase {
    func test_split_replacesClip_withTwoAdjacentClips() throws {
        var (project, clipID) = EditorFixture.minimalSingleClip()
        let originalSourceStart = try XCTUnwrap(project.clip(clipID)?.sourceRange.start)
        let originalSourceDuration = try XCTUnwrap(project.clip(clipID)?.sourceRange.duration)
        let originalTimelineStart = try XCTUnwrap(project.clip(clipID)?.timelineRange.start)
        let originalTimelineDuration = try XCTUnwrap(project.clip(clipID)?.timelineRange.duration)

        // Split at timeline = 1.5s (value 900 at timescale 600).
        let splitTime = EditorFixture.rt(value: 900)
        let cmd = SplitClipCommand(clipID: clipID, splitTime: splitTime)
        _ = try cmd.apply(to: &project)

        XCTAssertEqual(project.tracks[0].clips.count, 2)
        let left = project.tracks[0].clips[0]
        let right = project.tracks[0].clips[1]

        // Left half: timeline 0..1.5s, source 1..2.5s
        XCTAssertEqual(left.timelineRange.start, originalTimelineStart)
        XCTAssertEqual(left.timelineRange.duration.value, 900)
        XCTAssertEqual(left.sourceRange.start, originalSourceStart)
        XCTAssertEqual(left.sourceRange.duration.value, 900)

        // Right half: timeline 1.5..8s, source 2.5..9s
        XCTAssertEqual(right.timelineRange.start.value, 900)
        XCTAssertEqual(right.timelineRange.duration.value, originalTimelineDuration.value - 900)
        XCTAssertEqual(right.sourceRange.start.value, originalSourceStart.value + 900)
        XCTAssertEqual(right.sourceRange.duration.value, originalSourceDuration.value - 900)

        // Both halves get fresh IDs
        XCTAssertNotEqual(left.id, clipID)
        XCTAssertNotEqual(right.id, clipID)
        XCTAssertNotEqual(left.id, right.id)

        // Properties carried forward
        XCTAssertEqual(left.volume, 0.8)
        XCTAssertEqual(right.volume, 0.8)
        XCTAssertEqual(left.assetID, right.assetID)
    }

    func test_split_inverse_restoresOriginalClip() throws {
        var (project, clipID) = EditorFixture.minimalSingleClip()
        let originalClip = try XCTUnwrap(project.clip(clipID))

        let splitCmd = SplitClipCommand(clipID: clipID, splitTime: EditorFixture.rt(value: 1200))
        let inverse = try splitCmd.apply(to: &project)
        _ = try inverse.apply(to: &project)

        XCTAssertEqual(project.tracks[0].clips.count, 1)
        let restored = project.tracks[0].clips[0]
        // Restored clip has the original ID + ranges + properties.
        XCTAssertEqual(restored.id, originalClip.id)
        XCTAssertEqual(restored.sourceRange, originalClip.sourceRange)
        XCTAssertEqual(restored.timelineRange, originalClip.timelineRange)
        XCTAssertEqual(restored.volume, originalClip.volume)
    }

    func test_split_inverse_returnsCommandThatRedoesTheSplit() throws {
        var (project, clipID) = EditorFixture.minimalSingleClip()

        let splitTime = EditorFixture.rt(value: 1500)
        let inverse = try SplitClipCommand(clipID: clipID, splitTime: splitTime).apply(to: &project)
        let redo = try inverse.apply(to: &project)

        // Redo should be a SplitClip targeting the same original clip and time.
        let redoSplit = try XCTUnwrap(redo as? SplitClipCommand)
        XCTAssertEqual(redoSplit.clipID, clipID)
        XCTAssertEqual(redoSplit.splitTime, splitTime)
    }

    func test_split_atTimelineStart_throws() {
        var (project, clipID) = EditorFixture.minimalSingleClip()
        let timelineStart = project.clip(clipID)!.timelineRange.start
        let cmd = SplitClipCommand(clipID: clipID, splitTime: timelineStart)
        XCTAssertThrowsError(try cmd.apply(to: &project))
    }

    func test_split_atTimelineEnd_throws() {
        var (project, clipID) = EditorFixture.minimalSingleClip()
        let timelineEnd = project.clip(clipID)!.timelineRange.end
        let cmd = SplitClipCommand(clipID: clipID, splitTime: timelineEnd)
        XCTAssertThrowsError(try cmd.apply(to: &project))
    }

    func test_split_outsideTimelineRange_throws() {
        var (project, clipID) = EditorFixture.minimalSingleClip()
        let cmd = SplitClipCommand(clipID: clipID, splitTime: EditorFixture.rt(value: 99999))
        XCTAssertThrowsError(try cmd.apply(to: &project))
    }
}
