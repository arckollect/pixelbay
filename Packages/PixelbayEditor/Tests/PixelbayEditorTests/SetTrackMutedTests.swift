import PixelbayCore
@testable import PixelbayEditor
import XCTest

final class SetTrackMutedTests: XCTestCase {
    func test_apply_setsMuted_andReturnsInverseWithPriorValue() throws {
        var (project, trackID, _, _) = EditorFixture.twoClipsOneTrack()
        XCTAssertEqual(project.tracks.first(where: { $0.id == trackID })?.muted, false)

        let command = SetTrackMutedCommand(trackID: trackID, muted: true)
        let inverse = try command.apply(to: &project)
        XCTAssertEqual(project.tracks.first(where: { $0.id == trackID })?.muted, true)

        // Inverse carries the pre-state value (false).
        let inverseAsSet = try XCTUnwrap(inverse as? SetTrackMutedCommand)
        XCTAssertFalse(inverseAsSet.muted)
    }

    func test_inverse_restoresPriorMuted() throws {
        var (project, trackID, _, _) = EditorFixture.twoClipsOneTrack()
        let original = try XCTUnwrap(project.tracks.first(where: { $0.id == trackID })?.muted)

        let command = SetTrackMutedCommand(trackID: trackID, muted: true)
        let inverse = try command.apply(to: &project)
        _ = try inverse.apply(to: &project)
        XCTAssertEqual(project.tracks.first(where: { $0.id == trackID })?.muted, original)
    }

    func test_apply_throws_onMissingTrack() {
        var (project, _, _, _) = EditorFixture.twoClipsOneTrack()
        let bogus = TrackID(rawValue: "nonexistent")
        let command = SetTrackMutedCommand(trackID: bogus, muted: true)
        XCTAssertThrowsError(try command.apply(to: &project)) { error in
            XCTAssertEqual(error as? EditError, .trackNotFound(bogus))
        }
    }
}
