import XCTest
@testable import PixelbayEditor
import PixelbayCore

// Branch B (Slice B.4 + B.5) — exercises commands in
// `EditCommands+GroupedTimeline.swift`. Single test file per the
// separate-file rule so the merge surface against Branch A's
// EditCommands work stays mechanical.
final class GroupedTimelineCommandsTests: XCTestCase {

    // MARK: - SetLaneCollapsedCommand

    func test_setLaneCollapsed_setsExplicitValue() throws {
        var project = Project(name: "Test")
        // Smart-default seed = true → reads as collapsed.
        XCTAssertTrue(project.isLaneCollapsed(.video))
        XCTAssertNil(project.timelineLaneCollapse[.video],
                     "no explicit value yet — relying on default seed")

        let cmd = SetLaneCollapsedCommand(groupID: .video, collapsed: false)
        let inverse = try cmd.apply(to: &project)
        XCTAssertEqual(project.timelineLaneCollapse[.video], false)
        XCTAssertFalse(project.isLaneCollapsed(.video))

        // Inverse restores: previousValue was nil (no explicit setting
        // yet), so the inverse REMOVES the entry rather than setting it
        // to true. That way subsequent reads pick up the smart-default
        // seed again, not a stamped-true override.
        _ = try inverse.apply(to: &project)
        XCTAssertNil(project.timelineLaneCollapse[.video],
                     "inverse should remove the entry (restoring smart-default behaviour)")
    }

    func test_setLaneCollapsed_inverseRestoresPreviousExplicitValue() throws {
        var project = Project(name: "Test")
        project.timelineLaneCollapse = [.video: true, .audio: false]

        let cmd = SetLaneCollapsedCommand(groupID: .audio, collapsed: true)
        let inverse = try cmd.apply(to: &project)
        XCTAssertEqual(project.timelineLaneCollapse[.audio], true)

        _ = try inverse.apply(to: &project)
        XCTAssertEqual(project.timelineLaneCollapse[.audio], false,
                       "inverse should restore the previous explicit value")
        XCTAssertEqual(project.timelineLaneCollapse[.video], true,
                       "other lanes are untouched by single-lane toggle")
    }

    func test_setLaneCollapsed_undoRedoRoundTrip() throws {
        var project = Project(name: "Test")
        project.timelineLaneCollapse = [.video: false]
        let original = project.timelineLaneCollapse

        let apply = SetLaneCollapsedCommand(groupID: .video, collapsed: true)
        let inverse1 = try apply.apply(to: &project)
        let inverse2 = try inverse1.apply(to: &project)
        XCTAssertEqual(project.timelineLaneCollapse, original,
                       "after one apply + one inverse, state must match original")
        // Round-trip the inverse-of-inverse too — should restore the
        // post-apply state.
        _ = try inverse2.apply(to: &project)
        XCTAssertEqual(project.timelineLaneCollapse[.video], true)
    }

    // MARK: - SetAllLanesCollapsedCommand

    func test_setAllLanesCollapsed_bulkTogglesEveryLane() throws {
        var project = Project(name: "Test")
        project.timelineLaneCollapse = [.video: false, .audio: false]
        project.timelineLaneCollapseDefault = false

        _ = try SetAllLanesCollapsedCommand(collapsed: true).apply(to: &project)
        XCTAssertEqual(project.timelineLaneCollapse[.video], true)
        XCTAssertEqual(project.timelineLaneCollapse[.audio], true)
        XCTAssertEqual(project.timelineLaneCollapseDefault, true,
                       "default seed must also flip so future lanes obey")
    }

    func test_setAllLanesCollapsed_inverseRestoresFullPriorState() throws {
        var project = Project(name: "Test")
        project.timelineLaneCollapse = [.video: false]  // explicit
        project.timelineLaneCollapseDefault = true       // smart-default

        let cmd = SetAllLanesCollapsedCommand(collapsed: false)
        let inverse = try cmd.apply(to: &project)
        XCTAssertEqual(project.timelineLaneCollapse[.video], false)
        XCTAssertEqual(project.timelineLaneCollapse[.audio], false)
        XCTAssertEqual(project.timelineLaneCollapseDefault, false)

        _ = try inverse.apply(to: &project)
        // Branch B contract: full prior state restored, including the
        // partial map (audio was unset previously, must be unset again)
        // and the original default seed.
        XCTAssertEqual(project.timelineLaneCollapse[.video], false,
                       "video had explicit false before — same after restore")
        XCTAssertNil(project.timelineLaneCollapse[.audio],
                     "audio was unset before — should be unset again, not stamped false")
        XCTAssertEqual(project.timelineLaneCollapseDefault, true,
                       "default seed restored")
    }

    func test_setAllLanesCollapsed_redoAfterUndo_returnsToPostApplyState() throws {
        var project = Project(name: "Test")
        let apply = SetAllLanesCollapsedCommand(collapsed: false)
        let inverse = try apply.apply(to: &project)
        let redo = try inverse.apply(to: &project)
        _ = try redo.apply(to: &project)
        XCTAssertEqual(project.timelineLaneCollapse[.video], false)
        XCTAssertEqual(project.timelineLaneCollapse[.audio], false)
        XCTAssertEqual(project.timelineLaneCollapseDefault, false)
    }

    // MARK: - Group commands (Slice B.5)

    func test_clipsOnCollapsedLaneOverlapping_returnsLeadOnly_whenLaneExpanded() {
        let (project, screenID, _, _, _) = makeVideoAudioProject(collapsed: false)
        let group = project.clipsOnCollapsedLaneOverlapping(screenID)
        XCTAssertEqual(group, [screenID],
                       "expanded lane → no propagation, lead clip only")
    }

    func test_clipsOnCollapsedLaneOverlapping_includesOverlappingPeers_whenCollapsed() {
        let (project, screenID, camID, _, _) = makeVideoAudioProject(collapsed: true)
        let group = project.clipsOnCollapsedLaneOverlapping(screenID)
        XCTAssertTrue(group.contains(screenID))
        XCTAssertTrue(group.contains(camID),
                      "collapsed video lane: webcam clip overlapping screen clip joins the group")
    }

    func test_clipsOnCollapsedLaneOverlapping_excludesCrossGroupPeers() {
        let (project, screenID, _, micID, _) = makeVideoAudioProject(collapsed: true)
        let group = project.clipsOnCollapsedLaneOverlapping(screenID)
        XCTAssertFalse(group.contains(micID),
                       "audio-lane clip must not appear in the video group")
    }

    func test_trimClipsGroup_preservesSyncBetweenScreenAndCam_whenCollapsed() throws {
        let (originalProject, screenID, camID, _, _) = makeVideoAudioProject(collapsed: true)
        var project = originalProject
        let screenBefore = project.clip(screenID)!.timelineRange
        let camBefore = project.clip(camID)!.timelineRange
        let delta = RationalTime.seconds(0.5)
        let cmd = TrimClipsGroupCommand(clipIDs: [screenID, camID], delta: delta)
        let inverse = try cmd.apply(to: &project)
        let screenAfter = project.clip(screenID)!.timelineRange
        let camAfter = project.clip(camID)!.timelineRange
        XCTAssertEqual(screenAfter.start.seconds, screenBefore.start.seconds + 0.5, accuracy: 1e-9)
        XCTAssertEqual(camAfter.start.seconds, camBefore.start.seconds + 0.5, accuracy: 1e-9)
        // Inverse restores both clips exactly.
        _ = try inverse.apply(to: &project)
        XCTAssertEqual(project.clip(screenID)!.timelineRange.start.seconds,
                       screenBefore.start.seconds, accuracy: 1e-9)
        XCTAssertEqual(project.clip(camID)!.timelineRange.start.seconds,
                       camBefore.start.seconds, accuracy: 1e-9)
    }

    func test_trimClipsOutGroup_extendsEnd_preservesSync() throws {
        let (originalProject, screenID, camID, _, _) = makeVideoAudioProject(collapsed: true)
        var project = originalProject
        let screenBefore = project.clip(screenID)!.timelineRange
        let camBefore = project.clip(camID)!.timelineRange
        let delta = RationalTime.seconds(-0.25) // shrink the tail by 0.25s
        let cmd = TrimClipsOutGroupCommand(clipIDs: [screenID, camID], delta: delta)
        let inverse = try cmd.apply(to: &project)
        XCTAssertEqual(project.clip(screenID)!.timelineRange.duration.seconds,
                       screenBefore.duration.seconds - 0.25, accuracy: 1e-9)
        XCTAssertEqual(project.clip(camID)!.timelineRange.duration.seconds,
                       camBefore.duration.seconds - 0.25, accuracy: 1e-9)
        _ = try inverse.apply(to: &project)
        XCTAssertEqual(project.clip(screenID)!.timelineRange.duration.seconds,
                       screenBefore.duration.seconds, accuracy: 1e-9)
    }

    func test_moveClipsGroup_shiftsAllByLeadDelta() throws {
        let (originalProject, screenID, camID, _, _) = makeVideoAudioProject(collapsed: true)
        var project = originalProject
        let screenBefore = project.clip(screenID)!.timelineRange.start
        let camBefore = project.clip(camID)!.timelineRange.start
        // Move lead (screen) clip forward by 2 seconds.
        let cmd = MoveClipsGroupCommand(
            clipIDs: [screenID, camID],
            leadClipID: screenID,
            newTimelineStart: RationalTime.seconds(screenBefore.seconds + 2)
        )
        let inverse = try cmd.apply(to: &project)
        XCTAssertEqual(project.clip(screenID)!.timelineRange.start.seconds,
                       screenBefore.seconds + 2, accuracy: 1e-9)
        XCTAssertEqual(project.clip(camID)!.timelineRange.start.seconds,
                       camBefore.seconds + 2, accuracy: 1e-9,
                       "follower clip moves by the same delta as the lead")
        _ = try inverse.apply(to: &project)
        XCTAssertEqual(project.clip(screenID)!.timelineRange.start.seconds,
                       screenBefore.seconds, accuracy: 1e-9)
        XCTAssertEqual(project.clip(camID)!.timelineRange.start.seconds,
                       camBefore.seconds, accuracy: 1e-9)
    }

    func test_removeClipsGroup_removesAll_andInverseRestores() throws {
        let (originalProject, screenID, camID, _, _) = makeVideoAudioProject(collapsed: true)
        var project = originalProject
        let cmd = RemoveClipsGroupCommand(clipIDs: [screenID, camID])
        let inverse = try cmd.apply(to: &project)
        XCTAssertNil(project.clip(screenID))
        XCTAssertNil(project.clip(camID))
        _ = try inverse.apply(to: &project)
        XCTAssertNotNil(project.clip(screenID))
        XCTAssertNotNil(project.clip(camID))
    }

    func test_trimClipsGroup_rollsBack_whenAnyMemberFails() throws {
        // Build a project where the second clip's source range is at 0
        // and any negative trim-in delta would push it below zero —
        // forcing the per-clip command to throw. The whole group apply
        // must roll back, leaving the FIRST clip unchanged too.
        var project = Project(name: "Rollback")
        let asset = MediaAsset(kind: .display, relativePath: "media/s.mov",
                               captureStart: nil, nativeDuration: .seconds(5))
        let asset2 = MediaAsset(kind: .webcam, relativePath: "media/c.mov",
                                captureStart: nil, nativeDuration: .seconds(5))
        let clip1 = Clip(
            assetID: asset.id,
            sourceRange: TimeRange(start: .seconds(1), duration: .seconds(3)),
            timelineRange: TimeRange(start: .seconds(0), duration: .seconds(3))
        )
        let clip2 = Clip(
            assetID: asset2.id,
            sourceRange: TimeRange(start: .seconds(0), duration: .seconds(3)),
            timelineRange: TimeRange(start: .seconds(0), duration: .seconds(3))
        )
        project.assets = [asset, asset2]
        project.tracks = [
            Track(kind: .screen, name: "Screen", clips: [clip1]),
            Track(kind: .webcam, name: "Cam", clips: [clip2])
        ]
        let cmd = TrimClipsGroupCommand(
            clipIDs: [clip1.id, clip2.id],
            delta: .seconds(-0.5)  // tries to push clip2.sourceRange.start below 0
        )
        XCTAssertThrowsError(try cmd.apply(to: &project))
        // clip1 must NOT have been mutated — rollback should have
        // restored the entire project to the pre-apply state.
        XCTAssertEqual(project.clip(clip1.id)!.timelineRange.start.seconds, 0.0)
        XCTAssertEqual(project.clip(clip1.id)!.sourceRange.start.seconds, 1.0)
    }

    // MARK: - Decouple-on-expand (laneBreakout, polish 2026-05-27)

    func test_setLaneCollapsed_expand_setsLaneBreakoutOnAllMembers() throws {
        var (project, _, _, _, _) = makeVideoAudioProject(collapsed: true)
        // Pre-state: no track has breakout.
        for track in project.tracks where track.kind.laneGroup != nil {
            XCTAssertFalse(track.laneBreakout)
        }
        _ = try SetLaneCollapsedCommand(groupID: .video, collapsed: false).apply(to: &project)

        // Video-group members are broken out; audio-group members are not.
        let videoBreakouts = project.tracks
            .filter { $0.kind.laneGroup == .video }
            .map { $0.laneBreakout }
        XCTAssertEqual(videoBreakouts, [true, true])
        let audioBreakouts = project.tracks
            .filter { $0.kind.laneGroup == .audio }
            .map { $0.laneBreakout }
        XCTAssertEqual(audioBreakouts, [false, false])
    }

    func test_setLaneCollapsed_collapse_clearsLaneBreakoutOnAllMembers() throws {
        var (project, _, _, _, _) = makeVideoAudioProject(collapsed: false)
        // Force breakout on all members of both groups.
        for idx in project.tracks.indices where project.tracks[idx].kind.laneGroup != nil {
            project.tracks[idx].laneBreakout = true
        }
        _ = try SetLaneCollapsedCommand(groupID: .video, collapsed: true).apply(to: &project)

        let videoBreakouts = project.tracks
            .filter { $0.kind.laneGroup == .video }
            .map { $0.laneBreakout }
        XCTAssertEqual(videoBreakouts, [false, false], "collapse re-groups: breakouts cleared")
        let audioBreakouts = project.tracks
            .filter { $0.kind.laneGroup == .audio }
            .map { $0.laneBreakout }
        XCTAssertEqual(audioBreakouts, [true, true], "audio group untouched by video-only collapse")
    }

    func test_setLaneCollapsed_inverse_restoresPreviousBreakoutFlags() throws {
        var (project, _, _, _, _) = makeVideoAudioProject(collapsed: true)
        // Pre-state: webcam is already broken out, screen is not.
        if let idx = project.tracks.firstIndex(where: { $0.kind == .webcam }) {
            project.tracks[idx].laneBreakout = true
        }
        let inverse = try SetLaneCollapsedCommand(groupID: .video, collapsed: false).apply(to: &project)
        // Both members now broken out.
        XCTAssertTrue(project.tracks.first(where: { $0.kind == .screen })!.laneBreakout)
        XCTAssertTrue(project.tracks.first(where: { $0.kind == .webcam })!.laneBreakout)

        _ = try inverse.apply(to: &project)
        XCTAssertFalse(project.tracks.first(where: { $0.kind == .screen })!.laneBreakout,
                       "screen returns to its pre-apply (false) state")
        XCTAssertTrue(project.tracks.first(where: { $0.kind == .webcam })!.laneBreakout,
                      "webcam returns to its pre-apply (true) state — undo is exact")
    }

    func test_setAllLanesCollapsed_expand_breaksOutEveryGroupableTrack() throws {
        var (project, _, _, _, _) = makeVideoAudioProject(collapsed: true)
        _ = try SetAllLanesCollapsedCommand(collapsed: false).apply(to: &project)
        for track in project.tracks where track.kind.laneGroup != nil {
            XCTAssertTrue(track.laneBreakout, "every groupable track is broken out after Expand All")
        }
    }

    func test_setAllLanesCollapsed_collapse_clearsAllBreakouts() throws {
        var (project, _, _, _, _) = makeVideoAudioProject(collapsed: false)
        for idx in project.tracks.indices where project.tracks[idx].kind.laneGroup != nil {
            project.tracks[idx].laneBreakout = true
        }
        _ = try SetAllLanesCollapsedCommand(collapsed: true).apply(to: &project)
        for track in project.tracks where track.kind.laneGroup != nil {
            XCTAssertFalse(track.laneBreakout, "every breakout cleared after Collapse All")
        }
    }

    func test_clipsOnCollapsedLaneOverlapping_excludesBrokenOutMember() {
        var (project, screenID, _, _, _) = makeVideoAudioProject(collapsed: true)
        // With the lane collapsed and both tracks grouped, the helper
        // returns both video clips.
        let grouped = project.clipsOnCollapsedLaneOverlapping(screenID)
        XCTAssertEqual(grouped.count, 2)

        // Break out the webcam — its clip should NOT propagate anymore.
        if let idx = project.tracks.firstIndex(where: { $0.kind == .webcam }) {
            project.tracks[idx].laneBreakout = true
        }
        let filtered = project.clipsOnCollapsedLaneOverlapping(screenID)
        XCTAssertEqual(filtered, [screenID],
                       "broken-out webcam clip excluded from propagation")
    }

    func test_clipsOnCollapsedLaneOverlapping_brokenOutLeadStaysStandalone() {
        var (project, screenID, _, _, _) = makeVideoAudioProject(collapsed: true)
        if let idx = project.tracks.firstIndex(where: { $0.kind == .screen }) {
            project.tracks[idx].laneBreakout = true
        }
        // Lead is broken out → no propagation even though the lane map
        // still says "collapsed".
        XCTAssertEqual(project.clipsOnCollapsedLaneOverlapping(screenID), [screenID])
    }

    func test_laneBreakout_extras_roundTripsThroughCodable() throws {
        var project = Project(name: "Codec")
        var track = Track(kind: .webcam, name: "Cam", clips: [])
        track.laneBreakout = true
        project.tracks = [track]
        let data = try JSONEncoder().encode(project)
        let decoded = try JSONDecoder().decode(Project.self, from: data)
        XCTAssertTrue(decoded.tracks[0].laneBreakout)
    }

    // MARK: - Fixture for grouped-lane tests

    /// Two video tracks (screen + cam) + two audio tracks (mic + sys),
    /// all clips overlap at 0..3s. `collapsed` parameter seeds both
    /// lane groups to the desired state.
    private func makeVideoAudioProject(collapsed: Bool) -> (Project, ClipID, ClipID, ClipID, ClipID) {
        var project = Project(name: "VA")
        let assets: [MediaAsset] = [
            MediaAsset(kind: .display, relativePath: "media/s.mov", captureStart: nil, nativeDuration: .seconds(5)),
            MediaAsset(kind: .webcam, relativePath: "media/c.mov", captureStart: nil, nativeDuration: .seconds(5)),
            MediaAsset(kind: .microphone, relativePath: "media/m.m4a", captureStart: nil, nativeDuration: .seconds(5)),
            MediaAsset(kind: .systemAudio, relativePath: "media/a.m4a", captureStart: nil, nativeDuration: .seconds(5)),
        ]
        let clips = assets.map { asset in
            Clip(
                assetID: asset.id,
                sourceRange: TimeRange(start: .seconds(0.5), duration: .seconds(2.5)),
                timelineRange: TimeRange(start: .seconds(0), duration: .seconds(2.5))
            )
        }
        project.assets = assets
        project.tracks = [
            Track(kind: .screen, name: "Screen", clips: [clips[0]]),
            Track(kind: .webcam, name: "Cam", clips: [clips[1]]),
            Track(kind: .microphone, name: "Mic", clips: [clips[2]]),
            Track(kind: .systemAudio, name: "Sys", clips: [clips[3]])
        ]
        project.timelineLaneCollapse = [.video: collapsed, .audio: collapsed]
        return (project, clips[0].id, clips[1].id, clips[2].id, clips[3].id)
    }
}
