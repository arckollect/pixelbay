import PixelbayCore
@testable import PixelbayEditor
import XCTest

final class EditHistoryTests: XCTestCase {
    func test_freshHistory_hasNoUndoOrRedo() async {
        let (project, _) = EditorFixture.minimalSingleClip()
        let history = EditHistory(project: project)
        let canUndo = await history.canUndo
        let canRedo = await history.canRedo
        XCTAssertFalse(canUndo)
        XCTAssertFalse(canRedo)
    }

    func test_apply_pushesInverseOntoUndo_andClearsRedo() async throws {
        let (project, clipID) = EditorFixture.minimalSingleClip()
        let history = EditHistory(project: project)

        try await history.apply(SetClipVolumeCommand(clipID: clipID, newVolume: 0.3))
        let canUndo = await history.canUndo
        let canRedo = await history.canRedo
        XCTAssertTrue(canUndo)
        XCTAssertFalse(canRedo)
        let postProject = await history.project
        XCTAssertEqual(postProject.clip(clipID)?.volume, 0.3)
    }

    func test_undo_restoresPriorState_andEnablesRedo() async throws {
        let (project, clipID) = EditorFixture.minimalSingleClip()
        let history = EditHistory(project: project)
        try await history.apply(SetClipVolumeCommand(clipID: clipID, newVolume: 0.3))
        let didUndo = try await history.undo()
        XCTAssertTrue(didUndo)
        let undone = await history.project
        XCTAssertEqual(undone.clip(clipID)?.volume, 0.8)
        let canRedo = await history.canRedo
        XCTAssertTrue(canRedo)
    }

    func test_redo_replaysCommand() async throws {
        let (project, clipID) = EditorFixture.minimalSingleClip()
        let history = EditHistory(project: project)
        try await history.apply(SetClipVolumeCommand(clipID: clipID, newVolume: 0.3))
        try await history.undo()
        let didRedo = try await history.redo()
        XCTAssertTrue(didRedo)
        let redone = await history.project
        XCTAssertEqual(redone.clip(clipID)?.volume, 0.3)
    }

    func test_apply_after_undo_clearsRedoStack() async throws {
        let (project, clipID) = EditorFixture.minimalSingleClip()
        let history = EditHistory(project: project)
        try await history.apply(SetClipVolumeCommand(clipID: clipID, newVolume: 0.3))
        try await history.undo()
        // New apply should drop the redo branch.
        try await history.apply(SetClipVolumeCommand(clipID: clipID, newVolume: 0.5))
        let canRedo = await history.canRedo
        XCTAssertFalse(canRedo)
    }

    func test_undoActionName_matchesLastAppliedCommand() async throws {
        let (project, clipID) = EditorFixture.minimalSingleClip()
        let history = EditHistory(project: project)
        try await history.apply(SetClipVolumeCommand(clipID: clipID, newVolume: 0.5))
        let name = await history.undoActionName
        XCTAssertEqual(name, "Change Clip Volume")
    }

    func test_replace_dropsHistory() async throws {
        let (project, clipID) = EditorFixture.minimalSingleClip()
        let history = EditHistory(project: project)
        try await history.apply(SetClipVolumeCommand(clipID: clipID, newVolume: 0.5))
        let (replacement, _) = EditorFixture.minimalSingleClip()
        await history.replace(project: replacement)
        let canUndo = await history.canUndo
        let canRedo = await history.canRedo
        XCTAssertFalse(canUndo)
        XCTAssertFalse(canRedo)
    }

    func test_undo_redo_roundTrip_acrossMultipleCommands() async throws {
        let (project, clipID) = EditorFixture.minimalSingleClip()
        let history = EditHistory(project: project)
        try await history.apply(SetClipVolumeCommand(clipID: clipID, newVolume: 0.5))
        try await history.apply(TrimClipInCommand(clipID: clipID, delta: EditorFixture.rt(value: 600)))

        let after = await history.project
        XCTAssertEqual(after.clip(clipID)?.volume, 0.5)
        XCTAssertEqual(after.clip(clipID)?.sourceRange.start.value, 1200)

        try await history.undo()  // undoes trim
        let afterFirstUndo = await history.project
        XCTAssertEqual(afterFirstUndo.clip(clipID)?.sourceRange.start.value, 600)
        XCTAssertEqual(afterFirstUndo.clip(clipID)?.volume, 0.5)

        try await history.undo()  // undoes volume
        let afterSecondUndo = await history.project
        XCTAssertEqual(afterSecondUndo.clip(clipID)?.volume, 0.8)
    }

    func test_undo_redo_areNoOps_whenStacksEmpty() async throws {
        let (project, _) = EditorFixture.minimalSingleClip()
        let history = EditHistory(project: project)
        let didUndo = try await history.undo() // no-op
        let didRedo = try await history.redo() // no-op
        XCTAssertFalse(didUndo)
        XCTAssertFalse(didRedo)
        let canUndo = await history.canUndo
        XCTAssertFalse(canUndo)
    }
}
