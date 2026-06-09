import XCTest
@testable import PixelbayEditor
import PixelbayCore

final class ScenesMergerTests: XCTestCase {

    // MARK: - Helpers

    /// Builds a `(MediaAsset, Take)` pair representing one scene's recording.
    /// Every helper take has at least one screen asset (the realistic case);
    /// add audio-only variants explicitly in tests that exercise the
    /// `.screen`-less fallback.
    private func makeTake(
        sessionID: String,
        screenDurationSeconds: Double,
        includeWebcam: Bool = false,
        webcamDurationSeconds: Double? = nil,
        includeMic: Bool = false,
        micDurationSeconds: Double? = nil
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
                nativeDuration: .seconds(webcamDurationSeconds ?? screenDurationSeconds)
            ))
            ids.append(camID)
        }
        if includeMic {
            let micID = MediaAssetID.generate()
            assets.append(MediaAsset(
                id: micID,
                kind: .microphone,
                relativePath: "media/mic-\(sessionID).caf",
                nativeDuration: .seconds(micDurationSeconds ?? screenDurationSeconds)
            ))
            ids.append(micID)
        }

        let take = Take(
            sessionID: sessionID,
            assetIDs: ids,
            durationSeconds: screenDurationSeconds
        )
        return (assets, take)
    }

    // MARK: - Throw paths

    func test_merge_throwsWhenNoScenesSession() {
        var project = Project(name: "Plain")
        XCTAssertThrowsError(try ScenesMerger.merge(into: &project)) { error in
            guard case ScenesMerger.MergeError.noScenesSession = error else {
                return XCTFail("expected .noScenesSession, got \(error)")
            }
        }
    }

    func test_merge_throwsWhenActiveTakeReferencesMissingAsset() {
        let phantomID = MediaAssetID.generate()
        let take = Take(sessionID: "abc12345", assetIDs: [phantomID])
        let scene = Scene(takes: [take], activeTakeIndex: 0)
        let session = ScenesSession(scenes: [scene])
        var project = Project(name: "Phantom", scenesSession: session)

        XCTAssertThrowsError(try ScenesMerger.merge(into: &project)) { error in
            guard case ScenesMerger.MergeError.assetMissing(let id) = error else {
                return XCTFail("expected .assetMissing, got \(error)")
            }
            XCTAssertEqual(id, phantomID)
        }
        // Project must not be partially mutated when the merge throws.
        XCTAssertNotNil(project.scenesSession)
        XCTAssertTrue(project.tracks.isEmpty)
    }

    func test_merge_duplicateProjectAssetIDs_usesFirstAssetWithoutCrashing() throws {
        let sharedID = MediaAssetID.generate()
        let firstAsset = MediaAsset(
            id: sharedID,
            kind: .display,
            relativePath: "media/screen-first.mov",
            nativeDuration: .seconds(5)
        )
        let duplicateAsset = MediaAsset(
            id: sharedID,
            kind: .display,
            relativePath: "media/screen-duplicate.mov",
            nativeDuration: .seconds(9)
        )
        let take = Take(sessionID: "dupeasset", assetIDs: [sharedID])
        let scene = Scene(takes: [take], activeTakeIndex: 0)
        var project = Project(
            name: "Duplicate asset IDs",
            assets: [firstAsset, duplicateAsset],
            scenesSession: ScenesSession(scenes: [scene])
        )

        let merged = try ScenesMerger.merge(into: &project)

        XCTAssertEqual(merged, 1)
        XCTAssertEqual(project.tracks.count, 1)
        let clip = try XCTUnwrap(project.tracks.first?.clips.first)
        XCTAssertEqual(clip.assetID, sharedID)
        XCTAssertEqual(clip.sourceRange.duration.seconds, 5, accuracy: 1e-9)
        XCTAssertEqual(clip.timelineRange.duration.seconds, 5, accuracy: 1e-9)
    }

    func test_merge_throwsWhenActiveTakeHasNoAssets() {
        let take = Take(sessionID: "empty", assetIDs: [])
        let scene = Scene(takes: [take], activeTakeIndex: 0)
        let session = ScenesSession(scenes: [scene])
        var project = Project(name: "EmptyTake", scenesSession: session)

        XCTAssertThrowsError(try ScenesMerger.merge(into: &project)) { error in
            guard case ScenesMerger.MergeError.takeHasNoAssets(let id) = error else {
                return XCTFail("expected .takeHasNoAssets, got \(error)")
            }
            XCTAssertEqual(id, scene.id)
        }
    }

    // MARK: - Scene skipping

    func test_merge_skipsScenesWithNoActiveTake_andReturnsCorrectCount() throws {
        let (assets1, take1) = makeTake(sessionID: "scn1xxxx", screenDurationSeconds: 5)
        let scene1 = Scene(takes: [take1], activeTakeIndex: 0)

        // Scene 2 has no takes (never recorded).
        let scene2 = Scene()

        let (assets3, take3) = makeTake(sessionID: "scn3xxxx", screenDurationSeconds: 7)
        let scene3 = Scene(takes: [take3], activeTakeIndex: 0)

        let session = ScenesSession(scenes: [scene1, scene2, scene3])
        var project = Project(
            name: "Skip empty",
            assets: assets1 + assets3,
            scenesSession: session
        )

        let merged = try ScenesMerger.merge(into: &project)
        XCTAssertEqual(merged, 2)

        // One screen track, two clips (one per non-skipped scene).
        XCTAssertEqual(project.tracks.count, 1)
        XCTAssertEqual(project.tracks[0].kind, .screen)
        XCTAssertEqual(project.tracks[0].clips.count, 2)

        // Clips placed back-to-back: 0..5, then 5..12.
        let clipA = project.tracks[0].clips[0]
        let clipB = project.tracks[0].clips[1]
        XCTAssertEqual(clipA.timelineRange.start.seconds, 0, accuracy: 1e-9)
        XCTAssertEqual(clipA.timelineRange.duration.seconds, 5, accuracy: 1e-9)
        XCTAssertEqual(clipB.timelineRange.start.seconds, 5, accuracy: 1e-9)
        XCTAssertEqual(clipB.timelineRange.duration.seconds, 7, accuracy: 1e-9)
    }

    // MARK: - Back-to-back placement on shared tracks

    func test_merge_placesClipsBackToBack_acrossMultipleTrackKinds() throws {
        let (assets1, take1) = makeTake(
            sessionID: "s1aaaaaa",
            screenDurationSeconds: 4,
            includeWebcam: true,
            webcamDurationSeconds: 4,
            includeMic: true,
            micDurationSeconds: 4
        )
        let (assets2, take2) = makeTake(
            sessionID: "s2bbbbbb",
            screenDurationSeconds: 6,
            includeWebcam: true,
            webcamDurationSeconds: 6,
            includeMic: true,
            micDurationSeconds: 6
        )
        let scene1 = Scene(description: "Intro", takes: [take1], activeTakeIndex: 0)
        let scene2 = Scene(description: "Demo", takes: [take2], activeTakeIndex: 0)
        let session = ScenesSession(scenes: [scene1, scene2])
        var project = Project(
            name: "Multi-kind",
            assets: assets1 + assets2,
            scenesSession: session
        )

        let merged = try ScenesMerger.merge(into: &project)
        XCTAssertEqual(merged, 2)

        // Exactly one track per relevant TrackKind.
        let kinds = project.tracks.map { $0.kind }
        XCTAssertEqual(Set(kinds), Set([.screen, .webcam, .microphone]))
        XCTAssertEqual(project.tracks.count, 3)

        for track in project.tracks {
            XCTAssertEqual(track.clips.count, 2, "track \(track.kind) should have 2 clips")
            // Both clips back-to-back at offsets 0 and 4 (canonical = screen duration).
            XCTAssertEqual(track.clips[0].timelineRange.start.seconds, 0, accuracy: 1e-9)
            XCTAssertEqual(track.clips[1].timelineRange.start.seconds, 4, accuracy: 1e-9)
        }
    }

    func test_merge_reusesExistingTracksForLaterScenes() throws {
        // Three scenes back-to-back, all with screen + mic. We should still
        // end with exactly two tracks (one .screen, one .microphone), each
        // with three clips — track-per-kind is created on the first scene
        // and reused thereafter.
        let (a1, t1) = makeTake(sessionID: "s1", screenDurationSeconds: 2, includeMic: true)
        let (a2, t2) = makeTake(sessionID: "s2", screenDurationSeconds: 3, includeMic: true)
        let (a3, t3) = makeTake(sessionID: "s3", screenDurationSeconds: 1, includeMic: true)
        let scenes = [
            Scene(takes: [t1], activeTakeIndex: 0),
            Scene(takes: [t2], activeTakeIndex: 0),
            Scene(takes: [t3], activeTakeIndex: 0)
        ]
        var project = Project(
            name: "Reuse tracks",
            assets: a1 + a2 + a3,
            scenesSession: ScenesSession(scenes: scenes)
        )

        try ScenesMerger.merge(into: &project)
        XCTAssertEqual(project.tracks.count, 2)
        for track in project.tracks {
            XCTAssertEqual(track.clips.count, 3)
        }
    }

    // MARK: - Extras stamping

    func test_merge_stampsSceneIDOnEveryClip_andSceneDescriptionWhenNonEmpty() throws {
        let (assets1, take1) = makeTake(
            sessionID: "described",
            screenDurationSeconds: 5,
            includeWebcam: true
        )
        let (assets2, take2) = makeTake(sessionID: "bare", screenDurationSeconds: 5)
        let scene1 = Scene(
            description: "Walkthrough",
            takes: [take1],
            activeTakeIndex: 0
        )
        let scene2 = Scene(takes: [take2], activeTakeIndex: 0)
        var project = Project(
            name: "Extras test",
            assets: assets1 + assets2,
            scenesSession: ScenesSession(scenes: [scene1, scene2])
        )

        try ScenesMerger.merge(into: &project)

        let allClips = project.tracks.flatMap { $0.clips }
        XCTAssertFalse(allClips.isEmpty)

        // sceneID stamped on EVERY clip (both scenes).
        for clip in allClips {
            guard case .string(let raw)? = clip.extras["sceneID"] else {
                return XCTFail("missing sceneID extras on a merged clip")
            }
            XCTAssertTrue(raw == scene1.id.rawValue || raw == scene2.id.rawValue)
        }

        // sceneDescription only on scene1's clips.
        let s1Clips = allClips.filter {
            if case .string(let raw) = $0.extras["sceneID"] { return raw == scene1.id.rawValue }
            return false
        }
        let s2Clips = allClips.filter {
            if case .string(let raw) = $0.extras["sceneID"] { return raw == scene2.id.rawValue }
            return false
        }
        for clip in s1Clips {
            XCTAssertEqual(clip.extras["sceneDescription"], .string("Walkthrough"))
        }
        for clip in s2Clips {
            XCTAssertNil(clip.extras["sceneDescription"],
                         "empty descriptions must not be stamped")
        }
    }

    // MARK: - Source range invariants

    func test_merge_setsSourceRangeToFullAssetDuration() throws {
        // Scene clips slice from the start of the take's media (sourceRange
        // = [0, nativeDuration)). Trims happen on the resulting project, not
        // here.
        let (assets, take) = makeTake(sessionID: "trim", screenDurationSeconds: 9.5)
        let scene = Scene(takes: [take], activeTakeIndex: 0)
        var project = Project(
            name: "Source range",
            assets: assets,
            scenesSession: ScenesSession(scenes: [scene])
        )

        try ScenesMerger.merge(into: &project)
        let clip = project.tracks[0].clips[0]
        XCTAssertEqual(clip.sourceRange.start.seconds, 0, accuracy: 1e-9)
        XCTAssertEqual(clip.sourceRange.duration.seconds, 9.5, accuracy: 1e-9)
    }

    // MARK: - scenesSession cleared post-merge

    func test_merge_clearsScenesSession() throws {
        let (assets, take) = makeTake(sessionID: "x", screenDurationSeconds: 3)
        let scene = Scene(takes: [take], activeTakeIndex: 0)
        var project = Project(
            name: "Clear",
            assets: assets,
            scenesSession: ScenesSession(scenes: [scene])
        )
        try ScenesMerger.merge(into: &project)
        XCTAssertNil(project.scenesSession)
    }

    func test_merge_idempotenceProtection_throwsOnSecondCall() throws {
        let (assets, take) = makeTake(sessionID: "x", screenDurationSeconds: 3)
        var project = Project(
            name: "Idempotent",
            assets: assets,
            scenesSession: ScenesSession(scenes: [
                Scene(takes: [take], activeTakeIndex: 0)
            ])
        )
        try ScenesMerger.merge(into: &project)
        XCTAssertThrowsError(try ScenesMerger.merge(into: &project)) { error in
            guard case ScenesMerger.MergeError.noScenesSession = error else {
                return XCTFail("expected .noScenesSession on second merge")
            }
        }
    }

    // MARK: - Discarded takes left alone (decision #9)

    func test_merge_leavesNonActiveTakesAssetsInProjectAssets() throws {
        // Scene has two takes; only the second is active. The merge step
        // must not touch project.assets — Cleanup is the only pruning path.
        let (assets1, take1) = makeTake(sessionID: "old", screenDurationSeconds: 5)
        let (assets2, take2) = makeTake(sessionID: "new", screenDurationSeconds: 5)
        let scene = Scene(takes: [take1, take2], activeTakeIndex: 1)
        let assetsCountBefore = (assets1 + assets2).count
        var project = Project(
            name: "Discarded survive",
            assets: assets1 + assets2,
            scenesSession: ScenesSession(scenes: [scene])
        )

        try ScenesMerger.merge(into: &project)
        XCTAssertEqual(project.assets.count, assetsCountBefore,
                       "merge must not prune assets")

        // Verify only the active take's assets contributed clips.
        let clipAssetIDs = Set(project.tracks.flatMap { $0.clips }.map { $0.assetID })
        XCTAssertEqual(clipAssetIDs, Set(take2.assetIDs))
    }

    // MARK: - Long-source clamping (prevents shared-track overlap on merge)

    func test_merge_clampsLongerNonScreenAssetsToCanonicalSceneDuration() throws {
        // Scenario after the 2026-05-27 capture reorder: the cam pipeline
        // starts before SCStream so cam.mov is LONGER than screen.mov.
        // ScenesMerger must clamp the cam clip's timelineRange.duration
        // to the screen's nativeDuration (the scene's canonical length),
        // and use the tail of the cam source (sourceRange.start =
        // cam.duration − sceneDuration) so cam playback aligns with the
        // screen's wall-clock content.
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
            nativeDuration: .seconds(12)
        )
        let take = Take(sessionID: "abc", assetIDs: [screenID, camID], durationSeconds: 10)
        var project = Project(
            name: "Long cam",
            assets: [screenAsset, camAsset],
            scenesSession: ScenesSession(scenes: [
                Scene(takes: [take], activeTakeIndex: 0)
            ])
        )

        try ScenesMerger.merge(into: &project)

        let camTrack = project.tracks.first { $0.kind == .webcam }
        XCTAssertNotNil(camTrack)
        let camClip = camTrack?.clips.first
        XCTAssertNotNil(camClip)
        // timelineRange.duration is clamped to the screen's 10 s.
        XCTAssertEqual(camClip?.timelineRange.duration.seconds ?? 0, 10.0, accuracy: 1e-6)
        // sourceRange uses the tail: start = 12 − 10 = 2 s, duration = 10 s.
        XCTAssertEqual(camClip?.sourceRange.start.seconds ?? 0, 2.0, accuracy: 1e-6)
        XCTAssertEqual(camClip?.sourceRange.duration.seconds ?? 0, 10.0, accuracy: 1e-6)
    }

    func test_merge_shorterNonScreenAssetSpansCanonicalTimelineDuration() throws {
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
        var project = Project(
            name: "Short cam",
            assets: [screenAsset, camAsset],
            scenesSession: ScenesSession(scenes: [
                Scene(takes: [take], activeTakeIndex: 0)
            ])
        )

        try ScenesMerger.merge(into: &project)

        let camClip = try XCTUnwrap(project.tracks.first { $0.kind == .webcam }?.clips.first)
        XCTAssertEqual(camClip.sourceRange.start.seconds, 0, accuracy: 1e-6)
        XCTAssertEqual(camClip.sourceRange.duration.seconds, 3, accuracy: 1e-6)
        XCTAssertEqual(camClip.timelineRange.duration.seconds, 10, accuracy: 1e-6)
    }

    func test_merge_twoScenesWithLongerCam_producesNonOverlappingClipsOnSharedCamTrack() throws {
        // The actual user crash: two scenes back-to-back, each scene's
        // cam.mov is longer than its screen.mov. Previously the merger
        // wrote cam clip 1 as [0, 12.5] and cam clip 2 as [10.9, …],
        // which overlapped and crashed AVMutableAudioMix on the audio
        // side (and produced a broken video timeline). After the fix
        // both clips are clamped to their respective scene durations
        // and sit exactly back-to-back.
        let screen1 = MediaAsset(kind: .display, relativePath: "s1.mov", nativeDuration: .seconds(10.9))
        let cam1 = MediaAsset(kind: .webcam, relativePath: "c1.mov", nativeDuration: .seconds(12.5))
        let screen2 = MediaAsset(kind: .display, relativePath: "s2.mov", nativeDuration: .seconds(0.4))
        let cam2 = MediaAsset(kind: .webcam, relativePath: "c2.mov", nativeDuration: .seconds(2.3))

        let take1 = Take(sessionID: "s1", assetIDs: [screen1.id, cam1.id], durationSeconds: 10.9)
        let take2 = Take(sessionID: "s2", assetIDs: [screen2.id, cam2.id], durationSeconds: 0.4)
        var project = Project(
            name: "Two long-cam scenes",
            assets: [screen1, cam1, screen2, cam2],
            scenesSession: ScenesSession(scenes: [
                Scene(takes: [take1], activeTakeIndex: 0),
                Scene(takes: [take2], activeTakeIndex: 0)
            ])
        )

        try ScenesMerger.merge(into: &project)

        let camTrack = project.tracks.first { $0.kind == .webcam }
        XCTAssertEqual(camTrack?.clips.count, 2)
        let clipA = camTrack?.clips[0]
        let clipB = camTrack?.clips[1]
        XCTAssertEqual(clipA?.timelineRange.start.seconds ?? 0, 0.0, accuracy: 1e-6)
        XCTAssertEqual(clipA?.timelineRange.duration.seconds ?? 0, 10.9, accuracy: 1e-6)
        XCTAssertEqual(clipB?.timelineRange.start.seconds ?? 0, 10.9, accuracy: 1e-6)
        XCTAssertEqual(clipB?.timelineRange.duration.seconds ?? 0, 0.4, accuracy: 1e-6)
        // No overlap: clipA.end == clipB.start exactly.
        let aEnd = (clipA?.timelineRange.start.seconds ?? 0)
            + (clipA?.timelineRange.duration.seconds ?? 0)
        let bStart = clipB?.timelineRange.start.seconds ?? 0
        XCTAssertEqual(aEnd, bStart, accuracy: 1e-6)
    }

    // MARK: - Fallback when no screen asset is present

    func test_merge_audioOnlyScene_usesLongestAssetDurationAsRunningOffsetBasis() throws {
        // Edge case: a take with mic only (no screen). Canonical duration
        // falls back to the longest asset in the take so subsequent scenes
        // don't pile on top.
        let micID = MediaAssetID.generate()
        let micAsset = MediaAsset(
            id: micID,
            kind: .microphone,
            relativePath: "media/mic-x.caf",
            nativeDuration: .seconds(4)
        )
        let audioTake = Take(sessionID: "audio", assetIDs: [micID], durationSeconds: 4)
        let scene1 = Scene(takes: [audioTake], activeTakeIndex: 0)

        let (assets2, take2) = makeTake(sessionID: "with-screen", screenDurationSeconds: 6)
        let scene2 = Scene(takes: [take2], activeTakeIndex: 0)

        var project = Project(
            name: "Audio first",
            assets: [micAsset] + assets2,
            scenesSession: ScenesSession(scenes: [scene1, scene2])
        )
        try ScenesMerger.merge(into: &project)

        // First scene contributed a mic clip at offset 0 with duration 4s.
        let micTrack = project.tracks.first { $0.kind == .microphone }
        XCTAssertEqual(micTrack?.clips.first?.timelineRange.start.seconds, 0)
        XCTAssertEqual(micTrack?.clips.first?.timelineRange.duration.seconds, 4)

        // Second scene's screen clip must start at 4s, not 0s.
        let screenTrack = project.tracks.first { $0.kind == .screen }
        XCTAssertEqual(screenTrack?.clips.first?.timelineRange.start.seconds, 4)
    }
}
