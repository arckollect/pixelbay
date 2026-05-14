import PixelbayCore
@testable import PixelbayEditor
import XCTest

final class SetClipVolumeTests: XCTestCase {
    func test_apply_setsVolume_andReturnsInverseWithPriorValue() throws {
        var (project, clipID) = EditorFixture.minimalSingleClip()
        XCTAssertEqual(project.clip(clipID)?.volume, 0.8)

        let command = SetClipVolumeCommand(clipID: clipID, newVolume: 0.4)
        let inverse = try command.apply(to: &project)
        XCTAssertEqual(project.clip(clipID)?.volume, 0.4)

        // Inverse carries the pre-state value (0.8).
        let inverseAsSet = try XCTUnwrap(inverse as? SetClipVolumeCommand)
        XCTAssertEqual(inverseAsSet.newVolume, 0.8)
    }

    func test_inverse_restoresPriorVolume() throws {
        var (project, clipID) = EditorFixture.minimalSingleClip()
        let original = try XCTUnwrap(project.clip(clipID)?.volume)

        let command = SetClipVolumeCommand(clipID: clipID, newVolume: 1.5)
        let inverse = try command.apply(to: &project)
        _ = try inverse.apply(to: &project)
        XCTAssertEqual(project.clip(clipID)?.volume, original)
    }

    func test_apply_throws_onMissingClip() {
        var (project, _) = EditorFixture.minimalSingleClip()
        let bogus = ClipID(rawValue: "nonexistent")
        let command = SetClipVolumeCommand(clipID: bogus, newVolume: 0.5)
        XCTAssertThrowsError(try command.apply(to: &project)) { error in
            XCTAssertEqual(error as? EditError, .clipNotFound(bogus))
        }
    }

    func test_apply_throws_onNegativeVolume() {
        var (project, clipID) = EditorFixture.minimalSingleClip()
        let command = SetClipVolumeCommand(clipID: clipID, newVolume: -0.1)
        XCTAssertThrowsError(try command.apply(to: &project)) { error in
            XCTAssertEqual(error as? EditError, .invalidVolume(value: -0.1))
        }
    }
}
