import PixelbayCore
@testable import PixelbayEditor
import XCTest

final class ClipLifecycleTests: XCTestCase {
    // MARK: - InsertClip

    func test_insert_appendsClip_maintainingOrder() throws {
        var (project, trackID, _, _) = EditorFixture.twoClipsOneTrack()
        let assetID = project.assets[0].id
        // Insert a third clip in between (timeline 2400..3000 — between A and B).
        let middle = Clip(
            assetID: assetID,
            sourceRange: TimeRange(start: EditorFixture.rt(value: 0), duration: EditorFixture.rt(value: 600)),
            timelineRange: TimeRange(start: EditorFixture.rt(value: 2400), duration: EditorFixture.rt(value: 600))
        )
        _ = try InsertClipCommand(trackID: trackID, clip: middle).apply(to: &project)
        XCTAssertEqual(project.tracks[0].clips.count, 3)
        XCTAssertEqual(project.tracks[0].clips[1].id, middle.id)
    }

    func test_insert_inverse_isRemoveClip() throws {
        var (project, trackID, _, _) = EditorFixture.twoClipsOneTrack()
        let assetID = project.assets[0].id
        let newClip = Clip(
            assetID: assetID,
            sourceRange: TimeRange(start: EditorFixture.rt(value: 0), duration: EditorFixture.rt(value: 600)),
            timelineRange: TimeRange(start: EditorFixture.rt(value: 6000), duration: EditorFixture.rt(value: 600))
        )
        let inverse = try InsertClipCommand(trackID: trackID, clip: newClip).apply(to: &project)
        let inverseAsRemove = try XCTUnwrap(inverse as? RemoveClipCommand)
        XCTAssertEqual(inverseAsRemove.clipID, newClip.id)
        // Apply inverse, clip is gone.
        _ = try inverse.apply(to: &project)
        XCTAssertNil(project.clip(newClip.id))
        XCTAssertEqual(project.tracks[0].clips.count, 2)
    }

    func test_insert_throws_onUnknownTrack() {
        var (project, _, _, _) = EditorFixture.twoClipsOneTrack()
        let bogusTrack = TrackID(rawValue: "nope")
        let assetID = project.assets[0].id
        let clip = Clip(
            assetID: assetID,
            sourceRange: TimeRange(start: EditorFixture.rt(value: 0), duration: EditorFixture.rt(value: 600)),
            timelineRange: TimeRange(start: EditorFixture.rt(value: 0), duration: EditorFixture.rt(value: 600))
        )
        let cmd = InsertClipCommand(trackID: bogusTrack, clip: clip)
        XCTAssertThrowsError(try cmd.apply(to: &project)) { error in
            XCTAssertEqual(error as? EditError, .trackNotFound(bogusTrack))
        }
    }

    func test_insert_throws_onDuplicateClipID() throws {
        var (project, trackID, clipAID, _) = EditorFixture.twoClipsOneTrack()
        let existing = try XCTUnwrap(project.clip(clipAID))
        let cmd = InsertClipCommand(trackID: trackID, clip: existing)
        XCTAssertThrowsError(try cmd.apply(to: &project))
    }

    // MARK: - RemoveClip

    func test_remove_dropsClip_andReturnsInsertInverse() throws {
        var (project, _, clipAID, _) = EditorFixture.twoClipsOneTrack()
        let originalClip = try XCTUnwrap(project.clip(clipAID))

        let inverse = try RemoveClipCommand(clipID: clipAID).apply(to: &project)
        XCTAssertNil(project.clip(clipAID))
        XCTAssertEqual(project.tracks[0].clips.count, 1)

        let inverseAsInsert = try XCTUnwrap(inverse as? InsertClipCommand)
        XCTAssertEqual(inverseAsInsert.clip.id, originalClip.id)
        XCTAssertEqual(inverseAsInsert.clip.sourceRange, originalClip.sourceRange)
        XCTAssertEqual(inverseAsInsert.clip.volume, originalClip.volume)
    }

    func test_remove_then_insertInverse_restoresState() throws {
        var (project, _, clipAID, clipBID) = EditorFixture.twoClipsOneTrack()
        let beforeA = try XCTUnwrap(project.clip(clipAID))
        let beforeB = try XCTUnwrap(project.clip(clipBID))

        let inverse = try RemoveClipCommand(clipID: clipAID).apply(to: &project)
        _ = try inverse.apply(to: &project)

        XCTAssertEqual(project.tracks[0].clips.count, 2)
        XCTAssertEqual(project.clip(clipAID), beforeA)
        XCTAssertEqual(project.clip(clipBID), beforeB)
        // Order maintained: A first, B second.
        XCTAssertEqual(project.tracks[0].clips[0].id, clipAID)
        XCTAssertEqual(project.tracks[0].clips[1].id, clipBID)
    }

    func test_remove_throws_onUnknownClip() {
        var (project, _, _, _) = EditorFixture.twoClipsOneTrack()
        let bogus = ClipID(rawValue: "nope")
        XCTAssertThrowsError(try RemoveClipCommand(clipID: bogus).apply(to: &project))
    }
}
