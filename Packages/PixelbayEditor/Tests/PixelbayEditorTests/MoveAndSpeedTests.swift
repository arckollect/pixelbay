import PixelbayCore
@testable import PixelbayEditor
import XCTest

final class MoveAndSpeedTests: XCTestCase {
    // MARK: - Move

    func test_move_changesTimelineStart_preservingDuration() throws {
        var (project, clipID) = EditorFixture.minimalSingleClip()
        let priorDuration = try XCTUnwrap(project.clip(clipID)?.timelineRange.duration)
        let priorSourceRange = try XCTUnwrap(project.clip(clipID)?.sourceRange)

        _ = try MoveClipCommand(clipID: clipID, newTimelineStart: EditorFixture.rt(value: 1800)).apply(to: &project)

        let post = try XCTUnwrap(project.clip(clipID))
        XCTAssertEqual(post.timelineRange.start.value, 1800)
        XCTAssertEqual(post.timelineRange.duration, priorDuration)
        XCTAssertEqual(post.sourceRange, priorSourceRange)
    }

    func test_move_inverse_restoresOriginalStart() throws {
        var (project, clipID) = EditorFixture.minimalSingleClip()
        let priorStart = try XCTUnwrap(project.clip(clipID)?.timelineRange.start)
        let inverse = try MoveClipCommand(clipID: clipID, newTimelineStart: EditorFixture.rt(value: 1800)).apply(to: &project)
        _ = try inverse.apply(to: &project)
        XCTAssertEqual(project.clip(clipID)?.timelineRange.start, priorStart)
    }

    func test_move_throws_onNegativeTimelineStart() {
        var (project, clipID) = EditorFixture.minimalSingleClip()
        let cmd = MoveClipCommand(clipID: clipID, newTimelineStart: EditorFixture.rt(value: -100))
        XCTAssertThrowsError(try cmd.apply(to: &project))
    }

    func test_move_resortsTrack_whenClipPassesNeighbour() throws {
        // Two-clip fixture: A at timeline 0..4s, B at 5..9s. Move A to 6s
        // — it should now follow B in the array, not precede it.
        var (project, _, clipAID, clipBID) = EditorFixture.twoClipsOneTrack()
        _ = try MoveClipCommand(clipID: clipAID, newTimelineStart: EditorFixture.rt(value: 6000)).apply(to: &project)
        XCTAssertEqual(project.tracks[0].clips[0].id, clipBID, "B should be first after A moves past it")
        XCTAssertEqual(project.tracks[0].clips[1].id, clipAID)
    }

    // MARK: - SetClipSpeed

    func test_speed_setsValue_andReturnsInverseWithPriorValue() throws {
        var (project, clipID) = EditorFixture.minimalSingleClip()
        XCTAssertEqual(project.clip(clipID)?.speed, 1.0)
        let inverse = try SetClipSpeedCommand(clipID: clipID, newSpeed: 2.0).apply(to: &project)
        XCTAssertEqual(project.clip(clipID)?.speed, 2.0)
        let inverseAsSet = try XCTUnwrap(inverse as? SetClipSpeedCommand)
        XCTAssertEqual(inverseAsSet.newSpeed, 1.0)
    }

    func test_speed_throws_onZeroOrNegative() {
        var (project, clipID) = EditorFixture.minimalSingleClip()
        XCTAssertThrowsError(try SetClipSpeedCommand(clipID: clipID, newSpeed: 0).apply(to: &project))
        XCTAssertThrowsError(try SetClipSpeedCommand(clipID: clipID, newSpeed: -1).apply(to: &project))
    }

    func test_speed_inverse_restoresOriginalSpeed() throws {
        var (project, clipID) = EditorFixture.minimalSingleClip()
        let inverse = try SetClipSpeedCommand(clipID: clipID, newSpeed: 0.5).apply(to: &project)
        _ = try inverse.apply(to: &project)
        XCTAssertEqual(project.clip(clipID)?.speed, 1.0)
    }

    func test_speed_2x_halvesTimelineDuration() throws {
        // sourceRange = 4800 (8s @ ts=600), speed=2.0 → timelineRange = 4s.
        var (project, clipID) = EditorFixture.minimalSingleClip()
        let preSourceDur = try XCTUnwrap(project.clip(clipID)?.sourceRange.duration.value)
        XCTAssertEqual(preSourceDur, 4800)
        _ = try SetClipSpeedCommand(clipID: clipID, newSpeed: 2.0).apply(to: &project)
        let post = try XCTUnwrap(project.clip(clipID))
        XCTAssertEqual(post.speed, 2.0)
        XCTAssertEqual(post.sourceRange.duration.value, 4800, "sourceRange is canonical, unchanged")
        XCTAssertEqual(post.timelineRange.duration.value, 2400, "timelineRange = source / speed")
    }

    func test_speed_half_doublesTimelineDuration() throws {
        var (project, clipID) = EditorFixture.minimalSingleClip()
        _ = try SetClipSpeedCommand(clipID: clipID, newSpeed: 0.5).apply(to: &project)
        let post = try XCTUnwrap(project.clip(clipID))
        XCTAssertEqual(post.timelineRange.duration.value, 9600, "0.5× → 2× timeline")
    }

    func test_speed_inverse_restoresTimelineDuration() throws {
        var (project, clipID) = EditorFixture.minimalSingleClip()
        let preTimelineDur = try XCTUnwrap(project.clip(clipID)?.timelineRange.duration.value)
        let inverse = try SetClipSpeedCommand(clipID: clipID, newSpeed: 4.0).apply(to: &project)
        _ = try inverse.apply(to: &project)
        XCTAssertEqual(project.clip(clipID)?.speed, 1.0)
        XCTAssertEqual(project.clip(clipID)?.timelineRange.duration.value, preTimelineDur)
    }

    func test_speed_preservesTimelineStart() throws {
        // Setting speed must NOT shift the clip's start position. Only
        // its duration changes. Subsequent clips might overlap/gap, but
        // start is preserved (Phase 4 ripple-edit handles cascading).
        var (project, clipID) = EditorFixture.minimalSingleClip()
        let preStart = try XCTUnwrap(project.clip(clipID)?.timelineRange.start)
        _ = try SetClipSpeedCommand(clipID: clipID, newSpeed: 1.5).apply(to: &project)
        XCTAssertEqual(project.clip(clipID)?.timelineRange.start, preStart)
    }
}
