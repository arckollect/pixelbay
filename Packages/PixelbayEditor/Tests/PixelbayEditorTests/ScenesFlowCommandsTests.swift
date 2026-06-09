import XCTest
@testable import PixelbayEditor
import PixelbayCore

// Tests for Slice A.2's new scene-flow commands. Lives alongside the
// existing `EditCommands*Tests` files; named after the source file
// (`EditCommands+ScenesFlow.swift`) so future maintenance is easy to
// trace.
final class ScenesFlowCommandsTests: XCTestCase {

    // MARK: - SetClipExtraCommand

    func test_setClipExtra_setsKey_andInverseRestoresPriorValue() throws {
        var (project, clipID) = EditorFixture.minimalSingleClip()
        // Pre-condition: extras has no sceneDescription.
        XCTAssertNil(project.clip(clipID)?.extras["sceneDescription"])

        let inverse = try SetClipExtraCommand(
            clipID: clipID,
            key: "sceneDescription",
            value: .string("Intro")
        ).apply(to: &project)

        XCTAssertEqual(
            project.clip(clipID)?.extras["sceneDescription"],
            .string("Intro")
        )

        // Inverse should remove the key (prior value was nil).
        let inverseAsExtra = try XCTUnwrap(inverse as? SetClipExtraCommand)
        XCTAssertEqual(inverseAsExtra.key, "sceneDescription")
        XCTAssertNil(inverseAsExtra.value)

        _ = try inverse.apply(to: &project)
        XCTAssertNil(project.clip(clipID)?.extras["sceneDescription"])
    }

    func test_setClipExtra_overwritesExistingValue_andRoundTripsThroughUndo() throws {
        var (project, clipID) = EditorFixture.minimalSingleClip()
        // Seed an initial value.
        try project.mutateClip(clipID) { clip in
            clip.extras["sceneDescription"] = .string("Original")
        }

        let inverse = try SetClipExtraCommand(
            clipID: clipID,
            key: "sceneDescription",
            value: .string("Updated")
        ).apply(to: &project)

        XCTAssertEqual(
            project.clip(clipID)?.extras["sceneDescription"],
            .string("Updated")
        )

        // Inverse carries the prior string and restores it on apply.
        let inverseAsExtra = try XCTUnwrap(inverse as? SetClipExtraCommand)
        XCTAssertEqual(inverseAsExtra.value, .string("Original"))

        _ = try inverse.apply(to: &project)
        XCTAssertEqual(
            project.clip(clipID)?.extras["sceneDescription"],
            .string("Original")
        )
    }

    func test_setClipExtra_nilValueRemovesKey_andInverseRestoresPriorString() throws {
        var (project, clipID) = EditorFixture.minimalSingleClip()
        try project.mutateClip(clipID) { clip in
            clip.extras["sceneDescription"] = .string("Walkthrough")
        }

        let inverse = try SetClipExtraCommand(
            clipID: clipID,
            key: "sceneDescription",
            value: nil
        ).apply(to: &project)

        XCTAssertNil(project.clip(clipID)?.extras["sceneDescription"])

        _ = try inverse.apply(to: &project)
        XCTAssertEqual(
            project.clip(clipID)?.extras["sceneDescription"],
            .string("Walkthrough")
        )
    }

    func test_setClipExtra_throwsOnUnknownClip() {
        var (project, _) = EditorFixture.minimalSingleClip()
        let phantom = ClipID.generate()
        XCTAssertThrowsError(
            try SetClipExtraCommand(
                clipID: phantom,
                key: "sceneDescription",
                value: .string("x")
            ).apply(to: &project)
        )
    }

    // MARK: - MoveClipsByGroupCommand

    /// Builds a synthetic three-scene project: each scene has a screen +
    /// webcam clip on shared tracks, back-to-back at offsets 0/5/10 with
    /// 5-second durations. Every clip is tagged with its `sceneID`.
    private func makeThreeScenesProject() -> (Project, [String]) {
        // Two shared tracks: screen + webcam.
        let screenAssetIDs = (0..<3).map { _ in MediaAssetID.generate() }
        let camAssetIDs = (0..<3).map { _ in MediaAssetID.generate() }
        var assets: [MediaAsset] = []
        for (i, id) in screenAssetIDs.enumerated() {
            assets.append(MediaAsset(
                id: id,
                kind: .display,
                relativePath: "media/screen-\(i).mov",
                nativeDuration: .seconds(5)
            ))
        }
        for (i, id) in camAssetIDs.enumerated() {
            assets.append(MediaAsset(
                id: id,
                kind: .webcam,
                relativePath: "media/cam-\(i).mov",
                nativeDuration: .seconds(5)
            ))
        }

        let sceneIDs = (0..<3).map { _ in SceneID.generate().rawValue }
        let timescale: Int32 = 600

        func makeClip(assetID: MediaAssetID, sceneID: String, offsetSec: Double) -> Clip {
            Clip(
                assetID: assetID,
                sourceRange: TimeRange(start: .zero, duration: .seconds(5)),
                timelineRange: TimeRange(
                    start: RationalTime(value: Int64(offsetSec * Double(timescale)), timescale: timescale),
                    duration: RationalTime(value: Int64(5 * Double(timescale)), timescale: timescale)
                ),
                extras: ["sceneID": .string(sceneID)]
            )
        }

        let screenClips = (0..<3).map { i in
            makeClip(
                assetID: screenAssetIDs[i],
                sceneID: sceneIDs[i],
                offsetSec: Double(i) * 5.0
            )
        }
        let camClips = (0..<3).map { i in
            makeClip(
                assetID: camAssetIDs[i],
                sceneID: sceneIDs[i],
                offsetSec: Double(i) * 5.0
            )
        }
        let screenTrack = Track(kind: .screen, name: "Screen", clips: screenClips)
        let camTrack = Track(kind: .webcam, name: "Webcam", clips: camClips)
        var project = Project(name: "Three scenes")
        project.assets = assets
        project.tracks = [screenTrack, camTrack]
        return (project, sceneIDs)
    }

    func test_moveClipsByGroup_movesEntireSceneAcrossTracks_preservingSyncWithinScene() throws {
        var (project, sceneIDs) = makeThreeScenesProject()

        // Sanity: scene 0 starts at 0s on both tracks.
        XCTAssertEqual(project.tracks[0].clips[0].timelineRange.start.seconds, 0)
        XCTAssertEqual(project.tracks[1].clips[0].timelineRange.start.seconds, 0)

        // Move scene 0 to the end (target index 2). All clips with
        // sceneIDs[0] should now sit at the tail with start = 10s on both
        // tracks; scenes 1 and 2 should shift left into the freed space.
        _ = try MoveClipsByGroupCommand(
            sceneID: sceneIDs[0],
            targetSceneIndex: 2
        ).apply(to: &project)

        // Helper to find the clip carrying a given sceneID on a given track.
        func clipFor(sceneID: String, on trackIdx: Int) -> Clip? {
            project.tracks[trackIdx].clips.first { clip in
                if case .string(let id)? = clip.extras["sceneID"] { return id == sceneID }
                return false
            }
        }

        // Scene 0 should be at 10s on both screen and webcam.
        XCTAssertEqual(clipFor(sceneID: sceneIDs[0], on: 0)?.timelineRange.start.seconds ?? 0, 10.0, accuracy: 1e-6)
        XCTAssertEqual(clipFor(sceneID: sceneIDs[0], on: 1)?.timelineRange.start.seconds ?? 0, 10.0, accuracy: 1e-6)

        // Scene 1 moves to 0s, scene 2 moves to 5s.
        XCTAssertEqual(clipFor(sceneID: sceneIDs[1], on: 0)?.timelineRange.start.seconds ?? 0, 0.0, accuracy: 1e-6)
        XCTAssertEqual(clipFor(sceneID: sceneIDs[2], on: 0)?.timelineRange.start.seconds ?? 0, 5.0, accuracy: 1e-6)

        // Track order: clips should be sorted by timeline start ascending.
        for track in project.tracks {
            let starts = track.clips.map(\.timelineRange.start.seconds)
            XCTAssertEqual(starts, starts.sorted())
        }
    }

    func test_moveClipsByGroup_inverse_restoresOriginalOrder() throws {
        var (project, sceneIDs) = makeThreeScenesProject()

        // Snapshot original starts per (sceneID, trackIdx).
        var originalStarts: [String: [Double]] = [:]
        for sceneID in sceneIDs {
            var starts: [Double] = []
            for track in project.tracks {
                if let clip = track.clips.first(where: { clip in
                    if case .string(let id)? = clip.extras["sceneID"] { return id == sceneID }
                    return false
                }) {
                    starts.append(clip.timelineRange.start.seconds)
                }
            }
            originalStarts[sceneID] = starts
        }

        let inverse = try MoveClipsByGroupCommand(
            sceneID: sceneIDs[2],
            targetSceneIndex: 0
        ).apply(to: &project)

        _ = try inverse.apply(to: &project)

        // Re-read starts; should match original snapshot.
        for sceneID in sceneIDs {
            var starts: [Double] = []
            for track in project.tracks {
                if let clip = track.clips.first(where: { clip in
                    if case .string(let id)? = clip.extras["sceneID"] { return id == sceneID }
                    return false
                }) {
                    starts.append(clip.timelineRange.start.seconds)
                }
            }
            for (i, value) in starts.enumerated() {
                XCTAssertEqual(value, originalStarts[sceneID]![i], accuracy: 1e-6,
                               "round-trip didn't restore start for scene \(sceneID) track \(i)")
            }
        }
    }

    func test_moveClipsByGroup_noOp_whenTargetEqualsCurrent() throws {
        var (project, sceneIDs) = makeThreeScenesProject()
        // Scene 1 already sits at index 1; "move to 1" should be a no-op.
        let beforeStarts = project.tracks.flatMap(\.clips).map(\.timelineRange.start.seconds)
        _ = try MoveClipsByGroupCommand(
            sceneID: sceneIDs[1],
            targetSceneIndex: 1
        ).apply(to: &project)
        let afterStarts = project.tracks.flatMap(\.clips).map(\.timelineRange.start.seconds)
        XCTAssertEqual(beforeStarts, afterStarts)
    }

    func test_moveClipsByGroup_throwsWhenSceneIDNotFound() {
        var (project, _) = makeThreeScenesProject()
        let cmd = MoveClipsByGroupCommand(sceneID: "no-such-scene", targetSceneIndex: 0)
        XCTAssertThrowsError(try cmd.apply(to: &project))
    }

    func test_moveClipsByGroup_throwsWhenProjectHasNoSceneTaggedClips() {
        // Plain fixture has no sceneID extras → discovery is empty → throws.
        var (project, _) = EditorFixture.minimalSingleClip()
        let cmd = MoveClipsByGroupCommand(sceneID: "anything", targetSceneIndex: 0)
        XCTAssertThrowsError(try cmd.apply(to: &project))
    }

    // MARK: - ScenesMerger.mergeAppending

    /// Builds a `(MediaAsset, Take)` pair for one scene. Mirrors the helper
    /// in `ScenesMergerTests` so the append tests stay self-contained.
    private func makeTake(
        sessionID: String,
        screenDurationSeconds: Double,
        includeWebcam: Bool = false
    ) -> (assets: [MediaAsset], take: Take) {
        var assets: [MediaAsset] = []
        var ids: [MediaAssetID] = []
        let screenID = MediaAssetID.generate()
        assets.append(MediaAsset(
            id: screenID,
            kind: .display,
            relativePath: "media/screen-\(sessionID).mov",
            nativeDuration: .seconds(screenDurationSeconds)
        ))
        ids.append(screenID)
        if includeWebcam {
            let camID = MediaAssetID.generate()
            assets.append(MediaAsset(
                id: camID,
                kind: .webcam,
                relativePath: "media/cam-\(sessionID).mov",
                nativeDuration: .seconds(screenDurationSeconds)
            ))
            ids.append(camID)
        }
        let take = Take(
            sessionID: sessionID,
            assetIDs: ids,
            durationSeconds: screenDurationSeconds
        )
        return (assets, take)
    }

    func test_mergeAppending_placesClipsAfterExistingClips() throws {
        // Editor's existing project: one screen track with 5s of content.
        let existingAsset = MediaAsset(
            id: MediaAssetID.generate(),
            kind: .display,
            relativePath: "media/existing.mov",
            nativeDuration: .seconds(5)
        )
        let existingClip = Clip(
            assetID: existingAsset.id,
            sourceRange: TimeRange(start: .zero, duration: .seconds(5)),
            timelineRange: TimeRange(start: .zero, duration: .seconds(5))
        )
        let existingTrack = Track(kind: .screen, name: "Screen", clips: [existingClip])

        // New scenes session with one 3s scene.
        let (newAssets, newTake) = makeTake(sessionID: "appended", screenDurationSeconds: 3)
        let session = ScenesSession(scenes: [
            Scene(takes: [newTake], activeTakeIndex: 0)
        ])

        var project = Project(name: "Append target")
        project.assets = [existingAsset] + newAssets
        project.tracks = [existingTrack]
        project.scenesSession = session

        let merged = try ScenesMerger.mergeAppending(into: &project)
        XCTAssertEqual(merged, 1)
        XCTAssertNil(project.scenesSession, "scenesSession cleared after append-merge")

        // Same screen track now holds two clips: 0..5 (original) + 5..8 (new).
        let screenTrack = project.tracks.first { $0.kind == .screen }
        XCTAssertEqual(screenTrack?.clips.count, 2)
        let original = screenTrack?.clips[0]
        let appended = screenTrack?.clips[1]
        XCTAssertEqual(original?.timelineRange.start.seconds ?? -1, 0.0, accuracy: 1e-6)
        XCTAssertEqual(original?.timelineRange.duration.seconds ?? -1, 5.0, accuracy: 1e-6)
        XCTAssertEqual(appended?.timelineRange.start.seconds ?? -1, 5.0, accuracy: 1e-6)
        XCTAssertEqual(appended?.timelineRange.duration.seconds ?? -1, 3.0, accuracy: 1e-6)
        // sceneID stamped on the appended clip.
        XCTAssertNotNil(appended?.extras["sceneID"])
    }

    func test_mergeAppending_duplicateProjectAssetIDs_usesFirstAssetWithoutCrashing() throws {
        let existingAsset = MediaAsset(
            id: MediaAssetID.generate(),
            kind: .display,
            relativePath: "media/existing.mov",
            nativeDuration: .seconds(4)
        )
        let existingClip = Clip(
            assetID: existingAsset.id,
            sourceRange: TimeRange(start: .zero, duration: .seconds(4)),
            timelineRange: TimeRange(start: .zero, duration: .seconds(4))
        )

        let sharedID = MediaAssetID.generate()
        let firstAsset = MediaAsset(
            id: sharedID,
            kind: .display,
            relativePath: "media/screen-first.mov",
            nativeDuration: .seconds(3)
        )
        let duplicateAsset = MediaAsset(
            id: sharedID,
            kind: .display,
            relativePath: "media/screen-duplicate.mov",
            nativeDuration: .seconds(8)
        )
        let take = Take(sessionID: "dupeasset", assetIDs: [sharedID])

        var project = Project(name: "Append duplicate IDs")
        project.assets = [existingAsset, firstAsset, duplicateAsset]
        project.tracks = [
            Track(kind: .screen, name: "Screen", clips: [existingClip])
        ]
        project.scenesSession = ScenesSession(scenes: [
            Scene(takes: [take], activeTakeIndex: 0)
        ])

        let merged = try ScenesMerger.mergeAppending(into: &project)

        XCTAssertEqual(merged, 1)
        let screenTrack = try XCTUnwrap(project.tracks.first { $0.kind == .screen })
        XCTAssertEqual(screenTrack.clips.count, 2)
        let appended = screenTrack.clips[1]
        XCTAssertEqual(appended.assetID, sharedID)
        XCTAssertEqual(appended.timelineRange.start.seconds, 4, accuracy: 1e-9)
        XCTAssertEqual(appended.sourceRange.duration.seconds, 3, accuracy: 1e-9)
        XCTAssertEqual(appended.timelineRange.duration.seconds, 3, accuracy: 1e-9)
    }

    func test_mergeAppending_createsMissingTrack_whenNewSceneHasWebcamButProjectDoesNot() throws {
        // Editor project has only a screen track. New scene includes cam.
        let existingAsset = MediaAsset(
            id: MediaAssetID.generate(),
            kind: .display,
            relativePath: "media/existing.mov",
            nativeDuration: .seconds(4)
        )
        let existingClip = Clip(
            assetID: existingAsset.id,
            sourceRange: TimeRange(start: .zero, duration: .seconds(4)),
            timelineRange: TimeRange(start: .zero, duration: .seconds(4))
        )
        let existingTrack = Track(kind: .screen, name: "Screen", clips: [existingClip])

        let (newAssets, newTake) = makeTake(
            sessionID: "cam-too",
            screenDurationSeconds: 2,
            includeWebcam: true
        )
        let session = ScenesSession(scenes: [
            Scene(takes: [newTake], activeTakeIndex: 0)
        ])

        var project = Project(name: "Append target")
        project.assets = [existingAsset] + newAssets
        project.tracks = [existingTrack]
        project.scenesSession = session

        try ScenesMerger.mergeAppending(into: &project)

        // Verify webcam track was added with one clip at offset 4.
        let camTrack = project.tracks.first { $0.kind == .webcam }
        XCTAssertNotNil(camTrack, "mergeAppending should create the missing webcam track")
        XCTAssertEqual(camTrack?.clips.count, 1)
        XCTAssertEqual(camTrack?.clips.first?.timelineRange.start.seconds ?? -1, 4.0, accuracy: 1e-6)
        XCTAssertEqual(camTrack?.clips.first?.timelineRange.duration.seconds ?? -1, 2.0, accuracy: 1e-6)
    }

    func test_mergeAppending_shorterNonScreenAssetSpansCanonicalTimelineDuration() throws {
        let existingAsset = MediaAsset(
            id: MediaAssetID.generate(),
            kind: .display,
            relativePath: "media/existing.mov",
            nativeDuration: .seconds(4)
        )
        let existingClip = Clip(
            assetID: existingAsset.id,
            sourceRange: TimeRange(start: .zero, duration: .seconds(4)),
            timelineRange: TimeRange(start: .zero, duration: .seconds(4))
        )
        let screenID = MediaAssetID.generate()
        let camID = MediaAssetID.generate()
        let screenAsset = MediaAsset(
            id: screenID,
            kind: .display,
            relativePath: "media/screen.mov",
            nativeDuration: .seconds(10)
        )
        let camAsset = MediaAsset(
            id: camID,
            kind: .webcam,
            relativePath: "media/cam.mov",
            nativeDuration: .seconds(3)
        )
        let take = Take(sessionID: "shortcam", assetIDs: [screenID, camID], durationSeconds: 10)

        var project = Project(name: "Append short cam")
        project.assets = [existingAsset, screenAsset, camAsset]
        project.tracks = [
            Track(kind: .screen, name: "Screen", clips: [existingClip])
        ]
        project.scenesSession = ScenesSession(scenes: [
            Scene(takes: [take], activeTakeIndex: 0)
        ])

        try ScenesMerger.mergeAppending(into: &project)

        let camClip = try XCTUnwrap(project.tracks.first { $0.kind == .webcam }?.clips.first)
        XCTAssertEqual(camClip.timelineRange.start.seconds, 4, accuracy: 1e-6)
        XCTAssertEqual(camClip.timelineRange.duration.seconds, 10, accuracy: 1e-6)
        XCTAssertEqual(camClip.sourceRange.start.seconds, 0, accuracy: 1e-6)
        XCTAssertEqual(camClip.sourceRange.duration.seconds, 3, accuracy: 1e-6)
    }

    func test_mergeAppending_throwsWhenNoScenesSession() {
        var project = Project(name: "No session")
        XCTAssertThrowsError(try ScenesMerger.mergeAppending(into: &project)) { error in
            guard case ScenesMerger.MergeError.noScenesSession = error else {
                return XCTFail("expected .noScenesSession, got \(error)")
            }
        }
    }

    func test_appendAssetsCommand_skipsDuplicateIDsWithinSameBatch() throws {
        let sharedID = MediaAssetID.generate()
        let firstAsset = MediaAsset(
            id: sharedID,
            kind: .display,
            relativePath: "media/screen-first.mov",
            nativeDuration: .seconds(3)
        )
        let duplicateAsset = MediaAsset(
            id: sharedID,
            kind: .display,
            relativePath: "media/screen-duplicate.mov",
            nativeDuration: .seconds(7)
        )
        var project = Project(name: "Duplicate append batch")

        let inverse = try _AppendAssetsCommand(
            assets: [firstAsset, duplicateAsset]
        ).apply(to: &project)

        XCTAssertEqual(project.assets.count, 1)
        XCTAssertEqual(project.assets.first?.relativePath, "media/screen-first.mov")

        _ = try inverse.apply(to: &project)
        XCTAssertTrue(project.assets.isEmpty)
    }

    // MARK: - appendRecordingToTimeline-equivalent (Slice A.3)

    /// Mirrors `ProjectDocument.appendRecordingToTimeline`'s logic via direct
    /// command composition. The app-layer method walks the same
    /// `_AppendAssetsCommand` + `AddTrackCommand` + `InsertClipCommand`
    /// surface this test exercises, but lives in the app target with no
    /// test bundle. This pins the underlying contract so future changes to
    /// the commands won't silently break the timeline-end "+" path.
    func test_singleShotAppend_placesAssetsAtTail_acrossRelevantTracks() throws {
        // Editor's starting project: one screen track with 5s of content.
        let existingAsset = MediaAsset(
            id: MediaAssetID.generate(),
            kind: .display,
            relativePath: "media/existing.mov",
            nativeDuration: .seconds(5)
        )
        let existingClip = Clip(
            assetID: existingAsset.id,
            sourceRange: TimeRange(start: .zero, duration: .seconds(5)),
            timelineRange: TimeRange(start: .zero, duration: .seconds(5))
        )
        let existingTrack = Track(kind: .screen, name: "Screen", clips: [existingClip])
        var project = Project(name: "Append target")
        project.assets = [existingAsset]
        project.tracks = [existingTrack]

        // Simulate the RecordingService writing two new assets (screen 3s
        // + cam 3s) into project.assets. The popover's
        // `appendRecordingToTimeline` method runs `_AppendAssetsCommand`
        // to attach them to the in-memory project.
        let newScreen = MediaAsset(
            id: MediaAssetID.generate(),
            kind: .display,
            relativePath: "media/new-screen.mov",
            nativeDuration: .seconds(3)
        )
        let newCam = MediaAsset(
            id: MediaAssetID.generate(),
            kind: .webcam,
            relativePath: "media/new-cam.mov",
            nativeDuration: .seconds(3)
        )
        _ = try _AppendAssetsCommand(assets: [newScreen, newCam]).apply(to: &project)
        XCTAssertEqual(project.assets.count, 3)

        // Compute tail (5s) and insert: screen clip at 5..8 on the existing
        // screen track; cam clip at 5..8 on a NEW webcam track.
        let tail = RationalTime.seconds(5)
        let screenTrackID = project.tracks.first(where: { $0.kind == .screen })!.id

        let newScreenClip = Clip(
            assetID: newScreen.id,
            sourceRange: TimeRange(start: .zero, duration: .seconds(3)),
            timelineRange: TimeRange(start: tail, duration: .seconds(3))
        )
        _ = try InsertClipCommand(trackID: screenTrackID, clip: newScreenClip).apply(to: &project)

        // Webcam track doesn't exist yet → create + insert.
        let camTrack = Track(kind: .webcam, name: ScenesMerger.defaultTrackName(for: .webcam))
        _ = try AddTrackCommand(track: camTrack).apply(to: &project)
        let newCamClip = Clip(
            assetID: newCam.id,
            sourceRange: TimeRange(start: .zero, duration: .seconds(3)),
            timelineRange: TimeRange(start: tail, duration: .seconds(3))
        )
        _ = try InsertClipCommand(trackID: camTrack.id, clip: newCamClip).apply(to: &project)

        // Verify final shape.
        let screenTrack = project.tracks.first { $0.kind == .screen }
        XCTAssertEqual(screenTrack?.clips.count, 2)
        XCTAssertEqual(screenTrack?.clips[1].timelineRange.start.seconds ?? -1, 5.0, accuracy: 1e-6)
        XCTAssertEqual(screenTrack?.clips[1].timelineRange.duration.seconds ?? -1, 3.0, accuracy: 1e-6)
        XCTAssertNil(screenTrack?.clips[1].extras["sceneID"],
                     "single-shot append should NOT stamp sceneID — these aren't scenes")
        let camTrackPost = project.tracks.first { $0.kind == .webcam }
        XCTAssertNotNil(camTrackPost)
        XCTAssertEqual(camTrackPost?.clips.first?.timelineRange.start.seconds ?? -1, 5.0, accuracy: 1e-6)
    }
}
