import PixelbayCore
@testable import PixelbayEditor
import XCTest

final class TrackAndProjectTests: XCTestCase {
    // MARK: - AddTrack

    func test_addTrack_appendsByDefault() throws {
        var (project, _) = EditorFixture.minimalSingleClip()
        let initialCount = project.tracks.count
        let newTrack = Track(kind: .webcam, name: "Webcam")
        _ = try AddTrackCommand(track: newTrack).apply(to: &project)
        XCTAssertEqual(project.tracks.count, initialCount + 1)
        XCTAssertEqual(project.tracks.last?.id, newTrack.id)
    }

    func test_addTrack_insertsAtIndex_whenSpecified() throws {
        var (project, _) = EditorFixture.minimalSingleClip()
        let newTrack = Track(kind: .webcam, name: "Webcam")
        _ = try AddTrackCommand(track: newTrack, atIndex: 0).apply(to: &project)
        XCTAssertEqual(project.tracks[0].id, newTrack.id)
    }

    func test_addTrack_inverse_isRemoveTrack() throws {
        var (project, _) = EditorFixture.minimalSingleClip()
        let newTrack = Track(kind: .voiceover, name: "Voiceover")
        let inverse = try AddTrackCommand(track: newTrack).apply(to: &project)
        let inverseAsRemove = try XCTUnwrap(inverse as? RemoveTrackCommand)
        XCTAssertEqual(inverseAsRemove.trackID, newTrack.id)
        _ = try inverse.apply(to: &project)
        XCTAssertNil(project.locateTrack(newTrack.id))
    }

    func test_addTrack_throws_onDuplicateID() throws {
        var (project, _) = EditorFixture.minimalSingleClip()
        let existing = project.tracks[0]
        XCTAssertThrowsError(try AddTrackCommand(track: existing).apply(to: &project))
    }

    func test_addTrack_clampsOutOfBoundsIndex() throws {
        var (project, _) = EditorFixture.minimalSingleClip()
        let newTrack = Track(kind: .webcam, name: "Webcam")
        // atIndex: 99 should clamp to the end.
        _ = try AddTrackCommand(track: newTrack, atIndex: 99).apply(to: &project)
        XCTAssertEqual(project.tracks.last?.id, newTrack.id)
    }

    // MARK: - RemoveTrack

    func test_removeTrack_dropsTrack_andReturnsAddInverse() throws {
        var (project, _) = EditorFixture.minimalSingleClip()
        let trackID = project.tracks[0].id
        let originalTrack = project.tracks[0]

        let inverse = try RemoveTrackCommand(trackID: trackID).apply(to: &project)
        XCTAssertEqual(project.tracks.count, 0)

        let inverseAsAdd = try XCTUnwrap(inverse as? AddTrackCommand)
        XCTAssertEqual(inverseAsAdd.track.id, originalTrack.id)
        XCTAssertEqual(inverseAsAdd.atIndex, 0)
    }

    func test_removeTrack_inverse_restoresAtOriginalIndex() throws {
        var (project, _) = EditorFixture.minimalSingleClip()
        // Pad with a second track so index matters.
        let secondTrack = Track(kind: .webcam, name: "Webcam")
        _ = try AddTrackCommand(track: secondTrack).apply(to: &project)

        let firstTrackID = project.tracks[0].id
        let inverse = try RemoveTrackCommand(trackID: firstTrackID).apply(to: &project)
        XCTAssertEqual(project.tracks.count, 1)
        _ = try inverse.apply(to: &project)
        XCTAssertEqual(project.tracks.count, 2)
        XCTAssertEqual(project.tracks[0].id, firstTrackID, "Restored at original index 0")
    }

    func test_removeTrack_throws_onUnknownTrack() {
        var (project, _) = EditorFixture.minimalSingleClip()
        XCTAssertThrowsError(try RemoveTrackCommand(trackID: TrackID(rawValue: "nope")).apply(to: &project))
    }

    // MARK: - RenameProject

    func test_rename_updatesProjectName_andReturnsInverseWithPriorName() throws {
        var (project, _) = EditorFixture.minimalSingleClip()
        XCTAssertEqual(project.name, "Fixture")
        let inverse = try RenameProjectCommand(newName: "My Recording").apply(to: &project)
        XCTAssertEqual(project.name, "My Recording")
        let inverseAsRename = try XCTUnwrap(inverse as? RenameProjectCommand)
        XCTAssertEqual(inverseAsRename.newName, "Fixture")
        _ = try inverse.apply(to: &project)
        XCTAssertEqual(project.name, "Fixture")
    }

    // MARK: - SetLayoutPreset (Phase 3a)

    func test_setLayoutPreset_replacesProjectLayout_andInverseRestoresPrior() throws {
        var (project, _) = EditorFixture.minimalSingleClip()
        XCTAssertEqual(project.layout, .phase1Default)
        let newLayout = LayoutPreset(
            mode: .pip(position: .topLeft, size: .large),
            camShape: .circle,
            camCornerRadius: 0,
            background: .solid(color: RGBColor(r: 0.1, g: 0.1, b: 0.15)),
            padding: 40,
            screenCornerRadius: 16
        )
        let inverse = try SetLayoutPresetCommand(newLayout: newLayout).apply(to: &project)
        XCTAssertEqual(project.layout, newLayout)
        let inverseAsSet = try XCTUnwrap(inverse as? SetLayoutPresetCommand)
        XCTAssertEqual(inverseAsSet.newLayout, .phase1Default)
        _ = try inverse.apply(to: &project)
        XCTAssertEqual(project.layout, .phase1Default)
    }

    func test_setLayoutPreset_customBackgroundColors_roundTripThroughCodable() throws {
        var (project, _) = EditorFixture.minimalSingleClip()
        let solid = RGBColor(r: 0.42, g: 0.13, b: 0.77)
        let gradientFrom = RGBColor(r: 0.05, g: 0.92, b: 0.31)
        let gradientTo = RGBColor(r: 0.88, g: 0.66, b: 0.04)

        let solidPreset = LayoutPreset(background: .solid(color: solid), padding: 24)
        _ = try SetLayoutPresetCommand(newLayout: solidPreset).apply(to: &project)
        var data = try JSONEncoder().encode(project)
        var decoded = try JSONDecoder().decode(Project.self, from: data)
        XCTAssertEqual(decoded.layout.background, .solid(color: solid))

        let gradientPreset = LayoutPreset(
            background: .gradient(from: gradientFrom, to: gradientTo),
            padding: 24
        )
        _ = try SetLayoutPresetCommand(newLayout: gradientPreset).apply(to: &project)
        data = try JSONEncoder().encode(project)
        decoded = try JSONDecoder().decode(Project.self, from: data)
        XCTAssertEqual(decoded.layout.background, .gradient(from: gradientFrom, to: gradientTo))
    }
}
