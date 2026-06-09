import PixelbayCore
@testable import PixelbayEditor
import XCTest

final class TrimClipTests: XCTestCase {
    func test_trimIn_positiveDelta_shrinksClipFromStart() throws {
        var (project, clipID) = EditorFixture.minimalSingleClip()
        let priorSourceStart = try XCTUnwrap(project.clip(clipID)?.sourceRange.start)
        let priorSourceDuration = try XCTUnwrap(project.clip(clipID)?.sourceRange.duration)
        let priorTimelineStart = try XCTUnwrap(project.clip(clipID)?.timelineRange.start)
        let priorTimelineDuration = try XCTUnwrap(project.clip(clipID)?.timelineRange.duration)

        // Trim 1.0s off the head (delta = +600 at timescale 600).
        let delta = EditorFixture.rt(value: 600)
        let cmd = TrimClipInCommand(clipID: clipID, delta: delta)
        _ = try cmd.apply(to: &project)

        let post = try XCTUnwrap(project.clip(clipID))
        XCTAssertEqual(post.sourceRange.start.value, priorSourceStart.value + 600)
        XCTAssertEqual(post.sourceRange.duration.value, priorSourceDuration.value - 600)
        XCTAssertEqual(post.timelineRange.start.value, priorTimelineStart.value + 600)
        XCTAssertEqual(post.timelineRange.duration.value, priorTimelineDuration.value - 600)
    }

    func test_trimIn_acceptsDeltaWithDifferentTimescale() throws {
        var (project, clipID) = EditorFixture.minimalSingleClip()

        // 1s at timescale 1000. The command should normalize to the clip's
        // 600-timescale timeline range before applying exact arithmetic.
        let delta = RationalTime(value: 1_000, timescale: 1_000)
        _ = try TrimClipInCommand(clipID: clipID, delta: delta).apply(to: &project)

        let post = try XCTUnwrap(project.clip(clipID))
        XCTAssertEqual(post.sourceRange.start, EditorFixture.rt(value: 1_200))
        XCTAssertEqual(post.sourceRange.duration, EditorFixture.rt(value: 4_200))
        XCTAssertEqual(post.timelineRange.start, EditorFixture.rt(value: 600))
        XCTAssertEqual(post.timelineRange.duration, EditorFixture.rt(value: 4_200))
    }

    func test_trimIn_negativeDelta_expandsBackOut_recoveringTrimmedMaterial() throws {
        // The "drag clip edges back out" feature from HANDOFF §5 / Phase 2.
        // Source range starts at 1s into the asset (value 600); negative delta
        // -300 lets us drag the in-point back to 0.5s, recovering 0.5s of
        // previously-trimmed material.
        var (project, clipID) = EditorFixture.minimalSingleClip()
        let cmd = TrimClipInCommand(clipID: clipID, delta: EditorFixture.rt(value: -300))
        _ = try cmd.apply(to: &project)

        let post = try XCTUnwrap(project.clip(clipID))
        XCTAssertEqual(post.sourceRange.start.value, 300)
        XCTAssertEqual(post.sourceRange.duration.value, 4800 + 300)
    }

    func test_trimIn_inverse_restoresOriginalRanges() throws {
        var (project, clipID) = EditorFixture.minimalSingleClip()
        let pre = try XCTUnwrap(project.clip(clipID))

        let cmd = TrimClipInCommand(clipID: clipID, delta: EditorFixture.rt(value: 1200))
        let inverse = try cmd.apply(to: &project)
        _ = try inverse.apply(to: &project)

        let post = try XCTUnwrap(project.clip(clipID))
        XCTAssertEqual(post.sourceRange, pre.sourceRange)
        XCTAssertEqual(post.timelineRange, pre.timelineRange)
    }

    func test_trimIn_spedClip_scalesSourceDeltaBySpeed() throws {
        var (project, clipID) = EditorFixture.minimalSingleClip()
        _ = try SetClipSpeedCommand(clipID: clipID, newSpeed: 2.0).apply(to: &project)

        _ = try TrimClipInCommand(clipID: clipID, delta: EditorFixture.rt(value: 600)).apply(to: &project)

        let post = try XCTUnwrap(project.clip(clipID))
        XCTAssertEqual(post.speed, 2.0)
        XCTAssertEqual(post.sourceRange.start.value, 1_800)
        XCTAssertEqual(post.sourceRange.duration.value, 3_600)
        XCTAssertEqual(post.timelineRange.start.value, 600)
        XCTAssertEqual(post.timelineRange.duration.value, 1_800)
        XCTAssertEqual(
            post.sourceRange.duration.seconds / post.timelineRange.duration.seconds,
            2.0,
            accuracy: 1e-9
        )
    }

    func test_trimIn_throws_whenInPointWouldGoNegative() {
        var (project, clipID) = EditorFixture.minimalSingleClip()
        // sourceRange.start is 600; pulling back by 1000 would go to -400.
        let cmd = TrimClipInCommand(clipID: clipID, delta: EditorFixture.rt(value: -1000))
        XCTAssertThrowsError(try cmd.apply(to: &project)) { error in
            guard case .invalidSourceRange = error as? EditError else {
                return XCTFail("Expected invalidSourceRange, got \(error)")
            }
        }
    }

    func test_trimIn_throws_whenDurationWouldZero() {
        var (project, clipID) = EditorFixture.minimalSingleClip()
        // sourceRange.duration is 4800; trimming by 4800 would zero it.
        let cmd = TrimClipInCommand(clipID: clipID, delta: EditorFixture.rt(value: 4800))
        XCTAssertThrowsError(try cmd.apply(to: &project))
    }

    func test_trimOut_positiveDelta_extendsClip() throws {
        var (project, clipID) = EditorFixture.minimalSingleClip()
        let priorEnd = try XCTUnwrap(project.clip(clipID)?.sourceRange.duration)

        let cmd = TrimClipOutCommand(clipID: clipID, delta: EditorFixture.rt(value: 600))
        _ = try cmd.apply(to: &project)

        let post = try XCTUnwrap(project.clip(clipID))
        XCTAssertEqual(post.sourceRange.duration.value, priorEnd.value + 600)
        XCTAssertEqual(post.timelineRange.duration.value, priorEnd.value + 600)
    }

    func test_trimOut_acceptsDeltaWithDifferentTimescale() throws {
        var (project, clipID) = EditorFixture.minimalSingleClip()

        let delta = RationalTime(value: 1_000, timescale: 1_000)
        _ = try TrimClipOutCommand(clipID: clipID, delta: delta).apply(to: &project)

        let post = try XCTUnwrap(project.clip(clipID))
        XCTAssertEqual(post.sourceRange.duration, EditorFixture.rt(value: 5_400))
        XCTAssertEqual(post.timelineRange.duration, EditorFixture.rt(value: 5_400))
    }

    func test_trimOut_negativeDelta_shrinksFromTail() throws {
        var (project, clipID) = EditorFixture.minimalSingleClip()
        let cmd = TrimClipOutCommand(clipID: clipID, delta: EditorFixture.rt(value: -1200))
        _ = try cmd.apply(to: &project)
        let post = try XCTUnwrap(project.clip(clipID))
        XCTAssertEqual(post.sourceRange.duration.value, 4800 - 1200)
    }

    func test_trimOut_inverse_restoresOriginalRanges() throws {
        var (project, clipID) = EditorFixture.minimalSingleClip()
        let pre = try XCTUnwrap(project.clip(clipID))

        let cmd = TrimClipOutCommand(clipID: clipID, delta: EditorFixture.rt(value: 900))
        let inverse = try cmd.apply(to: &project)
        _ = try inverse.apply(to: &project)

        let post = try XCTUnwrap(project.clip(clipID))
        XCTAssertEqual(post.sourceRange, pre.sourceRange)
        XCTAssertEqual(post.timelineRange, pre.timelineRange)
    }

    func test_trimOut_slowClip_scalesSourceDeltaBySpeed() throws {
        var (project, clipID) = EditorFixture.minimalSingleClip()
        _ = try SetClipSpeedCommand(clipID: clipID, newSpeed: 0.5).apply(to: &project)

        _ = try TrimClipOutCommand(clipID: clipID, delta: EditorFixture.rt(value: -1_200)).apply(to: &project)

        let post = try XCTUnwrap(project.clip(clipID))
        XCTAssertEqual(post.speed, 0.5)
        XCTAssertEqual(post.sourceRange.duration.value, 4_200)
        XCTAssertEqual(post.timelineRange.duration.value, 8_400)
        XCTAssertEqual(
            post.sourceRange.duration.seconds / post.timelineRange.duration.seconds,
            0.5,
            accuracy: 1e-9
        )
    }

    func test_trimOut_throws_whenDurationWouldZero() {
        var (project, clipID) = EditorFixture.minimalSingleClip()
        let cmd = TrimClipOutCommand(clipID: clipID, delta: EditorFixture.rt(value: -4800))
        XCTAssertThrowsError(try cmd.apply(to: &project))
    }
}
