import XCTest
@testable import PixelbayEditor
import PixelbayCore

// Exercises the grouped-row commands in
// `EditCommands+GroupedTimeline.swift` and the overlap resolver that
// feeds them.
final class GroupedTimelineCommandsTests: XCTestCase {

    // MARK: - Overlap resolver

    func test_clipsOnLaneOverlapping_includesOverlappingPeers() {
        let (project, screenID, camID, _, _) = makeVideoAudioProject()
        let group = project.clipsOnLaneOverlapping(screenID)
        XCTAssertTrue(group.contains(screenID))
        XCTAssertTrue(group.contains(camID),
                      "webcam clip overlapping the screen clip joins the group")
    }

    func test_clipsOnLaneOverlapping_excludesCrossGroupPeers() {
        let (project, screenID, _, micID, _) = makeVideoAudioProject()
        let group = project.clipsOnLaneOverlapping(screenID)
        XCTAssertFalse(group.contains(micID),
                       "audio-lane clip must not appear in the video group")
    }

    func test_trimClipsGroup_preservesSyncBetweenScreenAndCam() throws {
        let (originalProject, screenID, camID, _, _) = makeVideoAudioProject()
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
        let (originalProject, screenID, camID, _, _) = makeVideoAudioProject()
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
        let (originalProject, screenID, camID, _, _) = makeVideoAudioProject()
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

    func test_moveClipsGroup_acceptsTargetStartWithDifferentTimescale() throws {
        let (originalProject, screenID, camID, _, _) = makeVideoAudioProject()
        var project = originalProject
        let screenBefore = project.clip(screenID)!.timelineRange.start
        let camBefore = project.clip(camID)!.timelineRange.start
        let newTimelineStart = RationalTime(
            value: Int64((screenBefore.seconds + 2.0) * 1_000),
            timescale: 1_000
        )

        _ = try MoveClipsGroupCommand(
            clipIDs: [screenID, camID],
            leadClipID: screenID,
            newTimelineStart: newTimelineStart
        ).apply(to: &project)

        XCTAssertEqual(project.clip(screenID)!.timelineRange.start.seconds,
                       screenBefore.seconds + 2.0, accuracy: 1e-9)
        XCTAssertEqual(project.clip(camID)!.timelineRange.start.seconds,
                       camBefore.seconds + 2.0, accuracy: 1e-9)
    }

    func test_removeClipsGroup_removesAll_andInverseRestores() throws {
        let (originalProject, screenID, camID, _, _) = makeVideoAudioProject()
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

    // MARK: - Fixture for grouped-lane tests

    /// Two video tracks (screen + cam) + two audio tracks (mic + sys),
    /// all clips overlap at 0..3s.
    private func makeVideoAudioProject() -> (Project, ClipID, ClipID, ClipID, ClipID) {
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
        return (project, clips[0].id, clips[1].id, clips[2].id, clips[3].id)
    }
}
