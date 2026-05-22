import PixelbayCore
@testable import PixelbayEditor
import PixelbayInputCapture
import XCTest

final class EffectKeyframeCommandsTests: XCTestCase {

    private func makeKeyframe(
        kind: EffectKind = .zoom,
        startSeconds: Double = 1.0,
        durationSeconds: Double = 2.0
    ) -> EffectKeyframe {
        EffectKeyframe(
            kind: kind,
            timelineRange: TimeRange(
                start: .seconds(startSeconds),
                duration: .seconds(durationSeconds)
            )
        )
    }

    // MARK: - AddEffectKeyframe

    func test_add_appendsKeyframe_andInverseRemovesIt() throws {
        var (project, _) = EditorFixture.minimalSingleClip()
        XCTAssertTrue(project.effects.isEmpty)
        let kf = makeKeyframe()
        let inverse = try AddEffectKeyframeCommand(keyframe: kf).apply(to: &project)
        XCTAssertEqual(project.effects.count, 1)
        XCTAssertEqual(project.effects[0].id, kf.id)
        let inverseAsRemove = try XCTUnwrap(inverse as? RemoveEffectKeyframeCommand)
        XCTAssertEqual(inverseAsRemove.keyframeID, kf.id)
        _ = try inverse.apply(to: &project)
        XCTAssertTrue(project.effects.isEmpty)
    }

    func test_add_rejectsZeroDurationKeyframe() {
        var (project, _) = EditorFixture.minimalSingleClip()
        let bad = EffectKeyframe(
            kind: .zoom,
            timelineRange: TimeRange(start: .seconds(1), duration: .seconds(0))
        )
        XCTAssertThrowsError(try AddEffectKeyframeCommand(keyframe: bad).apply(to: &project))
    }

    func test_add_rejectsNegativeStartKeyframe() {
        var (project, _) = EditorFixture.minimalSingleClip()
        let bad = EffectKeyframe(
            kind: .zoom,
            timelineRange: TimeRange(start: .seconds(-0.1), duration: .seconds(1))
        )
        XCTAssertThrowsError(try AddEffectKeyframeCommand(keyframe: bad).apply(to: &project))
    }

    func test_add_rejectsDuplicateID() throws {
        var (project, _) = EditorFixture.minimalSingleClip()
        let kf = makeKeyframe()
        _ = try AddEffectKeyframeCommand(keyframe: kf).apply(to: &project)
        XCTAssertThrowsError(try AddEffectKeyframeCommand(keyframe: kf).apply(to: &project))
    }

    // MARK: - RemoveEffectKeyframe

    func test_remove_dropsKeyframe_andInverseRestoresAtSameIndex() throws {
        var (project, _) = EditorFixture.minimalSingleClip()
        let kf1 = makeKeyframe(startSeconds: 1.0)
        let kf2 = makeKeyframe(startSeconds: 3.0)
        let kf3 = makeKeyframe(startSeconds: 5.0)
        _ = try AddEffectKeyframeCommand(keyframe: kf1).apply(to: &project)
        _ = try AddEffectKeyframeCommand(keyframe: kf2).apply(to: &project)
        _ = try AddEffectKeyframeCommand(keyframe: kf3).apply(to: &project)

        let inverse = try RemoveEffectKeyframeCommand(keyframeID: kf2.id).apply(to: &project)
        XCTAssertEqual(project.effects.map(\.id), [kf1.id, kf3.id])
        _ = try inverse.apply(to: &project)
        XCTAssertEqual(project.effects.map(\.id), [kf1.id, kf2.id, kf3.id])
    }

    func test_remove_throws_whenIDMissing() {
        var (project, _) = EditorFixture.minimalSingleClip()
        let ghost = EffectKeyframeID.generate()
        XCTAssertThrowsError(try RemoveEffectKeyframeCommand(keyframeID: ghost).apply(to: &project))
    }

    // MARK: - UpdateEffectKeyframe

    func test_update_replacesValues_andInverseRestoresPrior() throws {
        var (project, _) = EditorFixture.minimalSingleClip()
        let kf = makeKeyframe()
        _ = try AddEffectKeyframeCommand(keyframe: kf).apply(to: &project)
        let updated = EffectKeyframe(
            id: kf.id,
            kind: kf.kind,
            timelineRange: kf.timelineRange,
            zoomFactor: 2.5,
            centerX: 0.25,
            centerY: 0.75
        )
        let inverse = try UpdateEffectKeyframeCommand(keyframeID: kf.id, newValue: updated).apply(to: &project)
        XCTAssertEqual(project.effects[0].zoomFactor, 2.5)
        XCTAssertEqual(project.effects[0].centerX, 0.25)
        _ = try inverse.apply(to: &project)
        XCTAssertEqual(project.effects[0].zoomFactor, 1.5)
        XCTAssertEqual(project.effects[0].centerX, 0.5)
    }

    func test_update_preservesIDEvenIfNewValueHasDifferentID() throws {
        var (project, _) = EditorFixture.minimalSingleClip()
        let kf = makeKeyframe()
        _ = try AddEffectKeyframeCommand(keyframe: kf).apply(to: &project)
        let updated = EffectKeyframe(
            id: .generate(), // different id — should be ignored
            kind: kf.kind,
            timelineRange: kf.timelineRange,
            zoomFactor: 3.0
        )
        _ = try UpdateEffectKeyframeCommand(keyframeID: kf.id, newValue: updated).apply(to: &project)
        XCTAssertEqual(project.effects[0].id, kf.id, "update must preserve the original ID")
        XCTAssertEqual(project.effects[0].zoomFactor, 3.0)
    }

    func test_update_throws_onZeroDuration() throws {
        var (project, _) = EditorFixture.minimalSingleClip()
        let kf = makeKeyframe()
        _ = try AddEffectKeyframeCommand(keyframe: kf).apply(to: &project)
        let bad = EffectKeyframe(
            id: kf.id,
            kind: .zoom,
            timelineRange: TimeRange(start: .seconds(1), duration: .seconds(0))
        )
        XCTAssertThrowsError(try UpdateEffectKeyframeCommand(keyframeID: kf.id, newValue: bad).apply(to: &project))
    }

    // MARK: - GenerateAutoZoomFromClicks

    func test_autoZoom_widelySpacedClicks_generatesOneKeyframePerCluster() throws {
        var (project, _) = EditorFixture.minimalSingleClip()
        // Default lookahead 0.45 + hold 1.8 + easeOut 0.45 = 2.7s merge window.
        // Spacing these clicks 6s apart keeps each in its own cluster.
        let clicks = [
            AutoZoomClick(timelineTime: 2.0, centerX: 0.3, centerY: 0.7),
            AutoZoomClick(timelineTime: 8.0),
            AutoZoomClick(timelineTime: 14.0)
        ]
        _ = try GenerateAutoZoomFromClicksCommand(clicks: clicks)
            .apply(to: &project)
        XCTAssertEqual(project.effects.count, 3)
        XCTAssertEqual(project.effects[0].kind, .zoom)
        XCTAssertEqual(project.effects[0].centerX, 0.3, accuracy: 1e-9)
        XCTAssertEqual(project.effects[0].centerY, 0.7, accuracy: 1e-9)
    }

    func test_autoZoom_skipsClicksInsideLookaheadWindow() throws {
        var (project, _) = EditorFixture.minimalSingleClip()
        // Lookahead 0.5 → a click at t=0.1 has no room for the ramp.
        let clicks = [
            AutoZoomClick(timelineTime: 0.1),
            AutoZoomClick(timelineTime: 3.0)
        ]
        _ = try GenerateAutoZoomFromClicksCommand(clicks: clicks, lookahead: 0.5)
            .apply(to: &project)
        XCTAssertEqual(project.effects.count, 1)
    }

    func test_autoZoom_inverseRemovesGeneratedKeyframesOnly() throws {
        var (project, _) = EditorFixture.minimalSingleClip()
        // Pre-existing MANUAL user keyframe (origin = .manualHotkey) — must
        // survive both the regenerate-replace pass (only `.auto` keyframes
        // get wiped) AND the undo. Constructed away from where clicks land
        // so the manual-fence filter doesn't drop the clicks.
        let manual = EffectKeyframe(
            kind: .zoom,
            timelineRange: TimeRange(start: .seconds(0.1), duration: .seconds(0.5)),
            origin: .manualHotkey
        )
        _ = try AddEffectKeyframeCommand(keyframe: manual).apply(to: &project)

        // 6s gap so the two clicks land in separate clusters under the
        // default merge window (lookahead 0.45 + hold 1.8 + easeOut 0.45).
        let clicks = [AutoZoomClick(timelineTime: 4.0), AutoZoomClick(timelineTime: 10.0)]
        let inverse = try GenerateAutoZoomFromClicksCommand(clicks: clicks).apply(to: &project)
        XCTAssertEqual(project.effects.count, 3)
        _ = try inverse.apply(to: &project)
        XCTAssertEqual(project.effects.count, 1)
        XCTAssertEqual(project.effects[0].id, manual.id, "manual keyframe must survive undo")
    }

    // MARK: - Auto-zoom merge / dedupe (slice #11.c)

    func test_autoZoom_twoClicksInsideMergeWindow_collapseToOneKeyframe() throws {
        var (project, _) = EditorFixture.minimalSingleClip()
        // Defaults: lookahead 0.45, hold 1.8, easeOut 0.45 → merge window 2.7s.
        // Two clicks 0.5s apart land well inside that window. The merged
        // keyframe should: (a) span from the first click's zoom-in start
        // (4.0 - 0.45 = 3.55) to the second click's ease-out end
        // (4.5 + 1.8 + 0.45 = 6.75), and (b) carry the *latest* click's focal
        // point so the framing follows the user's attention. The clicks are
        // spatially distant (0.2 vs 0.8) to verify the focal-point follow,
        // so we pass `spatialResetThreshold: 1.0` to disable the spatial
        // break — its behaviour is covered separately below.
        let clicks = [
            AutoZoomClick(timelineTime: 4.0, centerX: 0.2, centerY: 0.2),
            AutoZoomClick(timelineTime: 4.5, centerX: 0.8, centerY: 0.8)
        ]
        _ = try GenerateAutoZoomFromClicksCommand(
            clicks: clicks,
            spatialResetThreshold: 1.0
        ).apply(to: &project)
        XCTAssertEqual(project.effects.count, 1)
        let kf = project.effects[0]
        XCTAssertEqual(kf.timelineRange.start.seconds, 3.55, accuracy: 1e-6)
        XCTAssertEqual(kf.timelineRange.duration.seconds, 3.2, accuracy: 1e-6)
        XCTAssertEqual(kf.centerX, 0.8, accuracy: 1e-9,
                       "merged cluster anchors at the latest click's focal point")
        XCTAssertEqual(kf.centerY, 0.8, accuracy: 1e-9)
    }

    func test_autoZoom_threeClicksInsideMergeWindow_collapseToOneKeyframe() throws {
        var (project, _) = EditorFixture.minimalSingleClip()
        // Three clicks each 0.6s apart — each fits inside the prior
        // cluster's running tail. Spatial-reset disabled to isolate the
        // time-merge behaviour (spatial is covered by its own test).
        let clicks = [
            AutoZoomClick(timelineTime: 4.0, centerX: 0.1, centerY: 0.1),
            AutoZoomClick(timelineTime: 4.6, centerX: 0.5, centerY: 0.5),
            AutoZoomClick(timelineTime: 5.2, centerX: 0.9, centerY: 0.9)
        ]
        _ = try GenerateAutoZoomFromClicksCommand(
            clicks: clicks,
            spatialResetThreshold: 1.0
        ).apply(to: &project)
        XCTAssertEqual(project.effects.count, 1)
        let kf = project.effects[0]
        XCTAssertEqual(kf.timelineRange.start.seconds, 3.55, accuracy: 1e-6)
        // Final cluster end follows the last click: 5.2 + 1.8 + 0.45 = 7.45.
        XCTAssertEqual(kf.timelineRange.duration.seconds, 3.9, accuracy: 1e-6)
        XCTAssertEqual(kf.centerX, 0.9, accuracy: 1e-9)
    }

    func test_autoZoom_twoClicksOutsideMergeWindow_stayAsTwoKeyframes() throws {
        var (project, _) = EditorFixture.minimalSingleClip()
        // Gap of 4s exceeds the 2.7s merge window — the clicks must stay in
        // separate clusters. Regression: don't over-merge unrelated clicks.
        let clicks = [
            AutoZoomClick(timelineTime: 4.0, centerX: 0.3, centerY: 0.3),
            AutoZoomClick(timelineTime: 8.0, centerX: 0.7, centerY: 0.7)
        ]
        _ = try GenerateAutoZoomFromClicksCommand(clicks: clicks).apply(to: &project)
        XCTAssertEqual(project.effects.count, 2)
        XCTAssertEqual(project.effects[0].centerX, 0.3, accuracy: 1e-9)
        XCTAssertEqual(project.effects[1].centerX, 0.7, accuracy: 1e-9)
    }

    func test_autoZoom_mergedCluster_trajectoryCoversWholeSpan() throws {
        var (project, _) = EditorFixture.minimalSingleClip()
        // Master trajectory: one sample per 0.5s across the merged span.
        let master = (0...20).map {
            MouseTrajectorySample(
                timelineTime: 0.5 * Double($0),
                centerX: 0.05 * Double($0),
                centerY: 0.0
            )
        }
        // Three clicks inside the merge window; expected merged keyframe
        // range: start = 4.0 - 0.45 = 3.55, end = 5.2 + 1.8 + 0.45 = 7.45.
        let clicks = [
            AutoZoomClick(timelineTime: 4.0),
            AutoZoomClick(timelineTime: 4.6),
            AutoZoomClick(timelineTime: 5.2)
        ]
        _ = try GenerateAutoZoomFromClicksCommand(
            clicks: clicks,
            mouseTrajectory: master
        ).apply(to: &project)

        XCTAssertEqual(project.effects.count, 1)
        let traj = try XCTUnwrap(project.effects[0].trajectory)
        // Master samples at t = 4.0, 4.5, 5.0, 5.5, 6.0, 6.5, 7.0 fall
        // inside the merged keyframe's [3.55, 7.45] range (rebased to
        // keyframe-local 0.45 … 3.45). That's 7 samples — more than the
        // 3-sample slices the unmerged path would have attached to each
        // standalone keyframe; the merged-trajectory window keeps
        // cursor-follow continuous across the cluster.
        XCTAssertEqual(traj.count, 7)
        XCTAssertEqual(traj.first?.t ?? -1, 0.45, accuracy: 1e-6)
        XCTAssertEqual(traj.last?.t ?? -1, 3.45, accuracy: 1e-6)
    }

    func test_autoZoom_mergedCluster_undoRemovesExactlyOneKeyframe() throws {
        var (project, _) = EditorFixture.minimalSingleClip()
        // Pre-existing MANUAL keyframe (origin = .manualHotkey) survives the
        // merged-cluster undo — proves the cluster's single ID is the only
        // thing the inverse removes, even though the cluster swallowed
        // multiple clicks. Range chosen so it doesn't overlap where clicks
        // generate their zoom range (clicks at 4-5s ⇒ keyframe ~[3.3, 6.8]).
        let manual = EffectKeyframe(
            kind: .zoom,
            timelineRange: TimeRange(start: .seconds(0.1), duration: .seconds(0.5)),
            origin: .manualHotkey
        )
        _ = try AddEffectKeyframeCommand(keyframe: manual).apply(to: &project)

        let clicks = [
            AutoZoomClick(timelineTime: 4.0),
            AutoZoomClick(timelineTime: 4.5),
            AutoZoomClick(timelineTime: 5.0)
        ]
        let inverse = try GenerateAutoZoomFromClicksCommand(clicks: clicks).apply(to: &project)
        XCTAssertEqual(project.effects.count, 2, "1 manual + 1 merged cluster")
        _ = try inverse.apply(to: &project)
        XCTAssertEqual(project.effects.count, 1)
        XCTAssertEqual(project.effects[0].id, manual.id)
    }

    func test_autoZoom_withoutTrajectory_keyframesHaveNilTrajectory() throws {
        var (project, _) = EditorFixture.minimalSingleClip()
        _ = try GenerateAutoZoomFromClicksCommand(
            clicks: [AutoZoomClick(timelineTime: 4.0)]
        ).apply(to: &project)
        XCTAssertEqual(project.effects.count, 1)
        XCTAssertNil(project.effects[0].trajectory)
    }

    func test_autoZoom_withTrajectory_attachesSliceToEachGeneratedKeyframe() throws {
        var (project, _) = EditorFixture.minimalSingleClip()
        // Master trajectory: one sample per second across the timeline.
        let master = (0...10).map {
            MouseTrajectorySample(timelineTime: Double($0), centerX: 0.1 * Double($0), centerY: 0.0)
        }
        // Two clicks at t=4 and t=8. With lookahead 0.5, hold 1.5, easeOut 0.5:
        // total duration 2.5s, so kf1 timeline range = [3.5, 6.0], kf2 = [7.5, 10.0].
        let clicks = [
            AutoZoomClick(timelineTime: 4.0),
            AutoZoomClick(timelineTime: 8.0)
        ]
        _ = try GenerateAutoZoomFromClicksCommand(
            clicks: clicks,
            lookahead: 0.5,
            holdDuration: 1.5,
            easeOutDuration: 0.5,
            mouseTrajectory: master
        ).apply(to: &project)

        XCTAssertEqual(project.effects.count, 2)

        // kf1: window [3.5, 6.0] → samples at t=4, t=5, t=6 (rebased to 0.5, 1.5, 2.5).
        let kf1Traj = try XCTUnwrap(project.effects[0].trajectory)
        XCTAssertEqual(kf1Traj.count, 3)
        XCTAssertEqual(kf1Traj[0].t, 0.5, accuracy: 1e-6)
        XCTAssertEqual(kf1Traj[0].x, 0.4, accuracy: 1e-6)
        XCTAssertEqual(kf1Traj[1].t, 1.5, accuracy: 1e-6)
        XCTAssertEqual(kf1Traj[1].x, 0.5, accuracy: 1e-6)
        XCTAssertEqual(kf1Traj[2].t, 2.5, accuracy: 1e-6)
        XCTAssertEqual(kf1Traj[2].x, 0.6, accuracy: 1e-6)

        // kf2: window [7.5, 10.0] → samples at t=8, t=9, t=10 (rebased to 0.5, 1.5, 2.5).
        let kf2Traj = try XCTUnwrap(project.effects[1].trajectory)
        XCTAssertEqual(kf2Traj.count, 3)
        XCTAssertEqual(kf2Traj[0].x, 0.8, accuracy: 1e-6)
        XCTAssertEqual(kf2Traj[2].x, 1.0, accuracy: 1e-6)
    }

    func test_autoZoom_withEmptyTrajectory_attachesEmptySliceNotNil() throws {
        var (project, _) = EditorFixture.minimalSingleClip()
        _ = try GenerateAutoZoomFromClicksCommand(
            clicks: [AutoZoomClick(timelineTime: 4.0)],
            mouseTrajectory: []
        ).apply(to: &project)
        XCTAssertEqual(project.effects.count, 1)
        // A trajectory was supplied — even an empty one signals the user
        // ran the trajectory-aware path. Persist the empty slice so the
        // generated keyframe's intent is preserved.
        XCTAssertEqual(project.effects[0].trajectory, [])
    }

    func test_autoZoom_trajectory_survivesUndoAndRedoCycle() throws {
        var (project, _) = EditorFixture.minimalSingleClip()
        let master = [
            MouseTrajectorySample(timelineTime: 4.0, centerX: 0.4, centerY: 0.4)
        ]
        let cmd = GenerateAutoZoomFromClicksCommand(
            clicks: [AutoZoomClick(timelineTime: 4.5)],
            lookahead: 0.5,
            holdDuration: 1.0,
            easeOutDuration: 0.5,
            mouseTrajectory: master
        )
        let inverse = try cmd.apply(to: &project)
        XCTAssertEqual(project.effects.count, 1)
        let originalKf = project.effects[0]
        XCTAssertEqual(originalKf.trajectory?.count, 1)

        let redo = try inverse.apply(to: &project)
        XCTAssertTrue(project.effects.isEmpty)

        _ = try redo.apply(to: &project)
        XCTAssertEqual(project.effects.count, 1)
        // Reinsert preserves the trajectory exactly.
        XCTAssertEqual(project.effects[0].trajectory, originalKf.trajectory)
    }

    func test_autoZoom_keyframeEaseInEqualsLookahead() throws {
        var (project, _) = EditorFixture.minimalSingleClip()
        let clicks = [AutoZoomClick(timelineTime: 3.0)]
        _ = try GenerateAutoZoomFromClicksCommand(clicks: clicks, lookahead: 0.4).apply(to: &project)
        let kf = project.effects[0]
        XCTAssertEqual(kf.easeIn.seconds, 0.4, accuracy: 1e-6)
        // Strength reaches ~1 at the click time (start + lookahead).
        let strengthAtClick = kf.strength(at: 3.0)
        XCTAssertGreaterThan(strengthAtClick, 0.95)
    }

    // MARK: - Cluster duration cap + spatial reset (slice #11.d)

    func test_autoZoom_clusterDurationCap_splitsAtMax() throws {
        var (project, _) = EditorFixture.minimalSingleClip()
        // Ten clicks 0.5s apart all at the same point — without a cap they
        // would all fold into one giant 10s+ cluster. With max=4.5s the
        // command emits multiple separate clusters.
        let clicks = (0..<10).map { i in
            AutoZoomClick(timelineTime: 4.0 + 0.5 * Double(i), centerX: 0.5, centerY: 0.5)
        }
        _ = try GenerateAutoZoomFromClicksCommand(
            clicks: clicks,
            maxClusterDuration: 4.5,
            spatialResetThreshold: 1.0  // disable spatial reset for this test
        ).apply(to: &project)
        XCTAssertGreaterThanOrEqual(project.effects.count, 2,
                                    "ten clicks across ~5s must produce >=2 clusters under a 4.5s cap")
        for kf in project.effects {
            XCTAssertLessThanOrEqual(kf.timelineRange.duration.seconds, 4.5 + 0.001,
                                     "no cluster may exceed the cap")
        }
    }

    func test_autoZoom_spatialReset_breaksClusterOnBigFocalJump() throws {
        var (project, _) = EditorFixture.minimalSingleClip()
        // Two clicks 1.5s apart but at opposite corners of the screen.
        // Default spatialResetThreshold = 0.30; distance is √2 ≈ 1.13,
        // far above. Result: 2 clusters, NOT 1. The spacing matters — L2's
        // forced-split truncation cuts the first cluster's tail to start at
        // click2-lookahead; with 1.5s spacing the truncated cluster is still
        // ≥ minVisibleDuration (1.25s = lookahead + easeOut + 0.05) so both
        // survive. Tighter spacing (≤ 1.25s) drops the first to avoid a
        // ramp-only flash — covered in
        // `test_autoZoom_forcedSplit_dropsPreviousClusterWhenTooShort`.
        let clicks = [
            AutoZoomClick(timelineTime: 4.0, centerX: 0.1, centerY: 0.1),
            AutoZoomClick(timelineTime: 5.5, centerX: 0.9, centerY: 0.9)
        ]
        _ = try GenerateAutoZoomFromClicksCommand(clicks: clicks).apply(to: &project)
        XCTAssertEqual(project.effects.count, 2,
                       "big focal-point jump must break the cluster")
    }

    func test_autoZoom_emittedKeyframesHaveAutoOrigin() throws {
        var (project, _) = EditorFixture.minimalSingleClip()
        _ = try GenerateAutoZoomFromClicksCommand(
            clicks: [AutoZoomClick(timelineTime: 4.0)]
        ).apply(to: &project)
        XCTAssertEqual(project.effects.first?.origin, .auto)
    }

    // MARK: - GenerateManualZoomsCommand (slice #11.d)

    func test_generateManualZooms_emitsOneKeyframePerMark_noClustering() throws {
        var (project, _) = EditorFixture.minimalSingleClip()
        // Three marks spaced past the per-mark range (lookahead 0.7 + hold 1.8
        // + easeOut 0.5 = 3.0s) so the overlap-dedup gate doesn't trigger and
        // the test stays focused on the original "no clustering" contract —
        // auto command would merge time-adjacent clicks; manual command emits
        // exactly one keyframe per mark when they don't overlap.
        let marks = [
            AutoZoomClick(timelineTime: 4.0, centerX: 0.3, centerY: 0.3),
            AutoZoomClick(timelineTime: 8.0, centerX: 0.5, centerY: 0.5),
            AutoZoomClick(timelineTime: 12.0, centerX: 0.7, centerY: 0.7)
        ]
        _ = try GenerateManualZoomsCommand(marks: marks).apply(to: &project)
        XCTAssertEqual(project.effects.count, 3)
        XCTAssertEqual(project.effects[0].centerX, 0.3, accuracy: 1e-9)
        XCTAssertEqual(project.effects[1].centerX, 0.5, accuracy: 1e-9)
        XCTAssertEqual(project.effects[2].centerX, 0.7, accuracy: 1e-9)
    }

    func test_generateManualZooms_emittedKeyframesHaveManualHotkeyOrigin() throws {
        var (project, _) = EditorFixture.minimalSingleClip()
        _ = try GenerateManualZoomsCommand(
            marks: [AutoZoomClick(timelineTime: 4.0)]
        ).apply(to: &project)
        XCTAssertEqual(project.effects.first?.origin, .manualHotkey)
    }

    func test_generateManualZooms_inverseRemovesOnlyManualKeyframes() throws {
        var (project, _) = EditorFixture.minimalSingleClip()
        // Add an auto-zoom keyframe first.
        let autoClicks = [AutoZoomClick(timelineTime: 2.0)]
        _ = try GenerateAutoZoomFromClicksCommand(clicks: autoClicks).apply(to: &project)
        XCTAssertEqual(project.effects.count, 1)

        // Then a manual mark elsewhere.
        let inverse = try GenerateManualZoomsCommand(
            marks: [AutoZoomClick(timelineTime: 8.0)]
        ).apply(to: &project)
        XCTAssertEqual(project.effects.count, 2)

        // Undo manual — the auto-zoom keyframe must survive.
        _ = try inverse.apply(to: &project)
        XCTAssertEqual(project.effects.count, 1)
        XCTAssertEqual(project.effects.first?.origin, .auto)
    }

    func test_generateManualZooms_skipsMarksThatDontFitTimeline() throws {
        var (project, _) = EditorFixture.minimalSingleClip()
        // Manual marks start AT mark.timelineTime. Default range duration =
        // easeIn 0.3 + hold 0.6 + easeOut 0.5 = 1.4s. With timelineDuration
        // 2.0, a mark at t=1.5 (range [1.5, 2.9)) overshoots; a mark at
        // t=0.5 (range [0.5, 1.9)) fits.
        _ = try GenerateManualZoomsCommand(
            marks: [AutoZoomClick(timelineTime: 0.5), AutoZoomClick(timelineTime: 1.5)],
            timelineDuration: 2.0
        ).apply(to: &project)
        XCTAssertEqual(project.effects.count, 1, "overshoot-end marks are skipped")
        XCTAssertEqual(project.effects[0].timelineRange.start.seconds, 0.5, accuracy: 1e-9)
    }

    func test_generateManualZooms_shakeGestureMark_emitsFollowCursorNoLookahead() throws {
        var (project, _) = EditorFixture.minimalSingleClip()
        let trajectory = (0...20).map {
            MouseTrajectorySample(
                timelineTime: 4.0 + Double($0) * 0.1,
                centerX: 0.5 + Double($0) * 0.01,
                centerY: 0.5
            )
        }
        _ = try GenerateManualZoomsCommand(
            marks: [AutoZoomClick(timelineTime: 4.0, source: .shakeGesture)],
            mouseTrajectory: trajectory
        ).apply(to: &project)
        XCTAssertEqual(project.effects.count, 1)
        XCTAssertNil(project.effects[0].trajectory,
                     "command leaves trajectory nil; PreviewComposition.applyCursorTrajectory fills it at composition build using the damped master")
        XCTAssertEqual(project.effects[0].anchorMode, .followCursor,
                       "shake marks use follow-cursor — anchorFollow's deadzone holds the anchor steady through small wiggles without the static-pin workaround")
        XCTAssertEqual(project.effects[0].followLeadSeconds, 0, accuracy: 1e-9,
                       "lookahead is 0 — an earlier iteration tried 0.15 but the first-sample clamp froze the anchor during ease-in while the cursor sprite kept moving, putting the cursor outside the viewport")
    }

    func test_generateManualZooms_circleGestureMark_emitsFollowCursorNoLookahead() throws {
        var (project, _) = EditorFixture.minimalSingleClip()
        let trajectory = [
            MouseTrajectorySample(timelineTime: 4.0, centerX: 0.5, centerY: 0.5),
            MouseTrajectorySample(timelineTime: 4.5, centerX: 0.6, centerY: 0.5)
        ]
        _ = try GenerateManualZoomsCommand(
            marks: [AutoZoomClick(timelineTime: 4.0, source: .circleGesture)],
            mouseTrajectory: trajectory
        ).apply(to: &project)
        XCTAssertEqual(project.effects.count, 1)
        XCTAssertNil(project.effects[0].trajectory)
        XCTAssertEqual(project.effects[0].anchorMode, .followCursor)
        XCTAssertEqual(project.effects[0].followLeadSeconds, 0, accuracy: 1e-9,
                       "circle marks share the same no-lookahead policy as shake marks")
    }

    func test_generateManualZooms_hotkeyMark_emitsFollowCursorNoLookahead() throws {
        var (project, _) = EditorFixture.minimalSingleClip()
        let trajectory = [
            MouseTrajectorySample(timelineTime: 4.0, centerX: 0.5, centerY: 0.5),
            MouseTrajectorySample(timelineTime: 4.5, centerX: 0.7, centerY: 0.5)
        ]
        _ = try GenerateManualZoomsCommand(
            marks: [AutoZoomClick(timelineTime: 4.0, source: .hotkey)],
            mouseTrajectory: trajectory
        ).apply(to: &project)
        XCTAssertEqual(project.effects.count, 1)
        XCTAssertEqual(project.effects[0].anchorMode, .followCursor)
        XCTAssertEqual(project.effects[0].followLeadSeconds, 0, accuracy: 1e-9)
    }

    func test_generateManualZooms_nilSourceMark_treatedAsGesture_followCursor() throws {
        // Pre-source-tag sidecars (v4) decode marks with source == nil.
        // Treated as gesture-equivalent — same follow-cursor + no-lookahead
        // policy. The earlier static-pin back-compat path is gone now
        // that anchorFollow's deadzone handles the wiggle jitter.
        var (project, _) = EditorFixture.minimalSingleClip()
        let trajectory = [
            MouseTrajectorySample(timelineTime: 4.0, centerX: 0.5, centerY: 0.5),
            MouseTrajectorySample(timelineTime: 4.5, centerX: 0.7, centerY: 0.5)
        ]
        _ = try GenerateManualZoomsCommand(
            marks: [AutoZoomClick(timelineTime: 4.0, source: nil)],
            mouseTrajectory: trajectory
        ).apply(to: &project)
        XCTAssertEqual(project.effects.count, 1)
        XCTAssertEqual(project.effects[0].anchorMode, .followCursor)
        XCTAssertEqual(project.effects[0].followLeadSeconds, 0, accuracy: 1e-9)
    }

    func test_generateManualZooms_zoomStartsAtMarkTimestamp_notBefore() throws {
        var (project, _) = EditorFixture.minimalSingleClip()
        // Timing contract for gesture-emitted marks: detector emits the
        // gesture-START timestamp (window[0]), so range.start = gesture
        // start. Zoom ramps in across the gesture motion (~0.3s easeIn),
        // brief hold (0.6s), ease-out (0.5s) — total 1.4s response.
        _ = try GenerateManualZoomsCommand(
            marks: [AutoZoomClick(timelineTime: 4.0)]
        ).apply(to: &project)
        XCTAssertEqual(project.effects.count, 1)
        XCTAssertEqual(project.effects[0].timelineRange.start.seconds, 4.0, accuracy: 1e-9,
                       "manual zoom starts at the mark (= gesture start)")
        // Range end = 4.0 + 0.3 (easeIn) + 0.6 (hold) + 0.5 (easeOut) = 5.4.
        XCTAssertEqual(project.effects[0].timelineRange.end.seconds, 5.4, accuracy: 1e-9)
    }

    func test_generateManualZooms_gestureMark_preservesRawAnchorCoordinates() throws {
        // Earlier (pre-2026-05-17) gesture marks magnet-snapped to a 0.10
        // norm-unit grid to mask sub-cell jitter on the static-pin design.
        // anchor-follow makes that snap unnecessary AND counterproductive —
        // the spring naturally smooths the cluster, while a grid snap
        // would yank the anchor away from where the user pointed. Coords
        // must now pass through unmodified for all sources.
        var (project, _) = EditorFixture.minimalSingleClip()
        _ = try GenerateManualZoomsCommand(
            marks: [
                AutoZoomClick(timelineTime: 4.0, centerX: 0.523, centerY: 0.487,
                              source: .shakeGesture),
                AutoZoomClick(timelineTime: 6.0, centerX: 0.55, centerY: 0.55,
                              source: .shakeGesture),
                AutoZoomClick(timelineTime: 8.0, centerX: 0.54, centerY: 0.46,
                              source: .shakeGesture)
            ]
        ).apply(to: &project)
        XCTAssertEqual(project.effects.count, 3)
        let sorted = project.effects.sorted { $0.timelineRange.start.seconds < $1.timelineRange.start.seconds }
        XCTAssertEqual(sorted[0].centerX, 0.523, accuracy: 1e-9,
                       "gesture marks no longer magnet-snap — coords pass through")
        XCTAssertEqual(sorted[0].centerY, 0.487, accuracy: 1e-9)
        XCTAssertEqual(sorted[1].centerX, 0.55, accuracy: 1e-9)
        XCTAssertEqual(sorted[1].centerY, 0.55, accuracy: 1e-9)
        XCTAssertEqual(sorted[2].centerX, 0.54, accuracy: 1e-9)
        XCTAssertEqual(sorted[2].centerY, 0.46, accuracy: 1e-9)
    }

    func test_generateManualZooms_hotkeyMark_preservesRawAnchorCoordinates() throws {
        // Hotkey marks have always passed through unmodified; covered here
        // alongside the gesture variant to pin the symmetry now that
        // magnet-snap is gone for both.
        var (project, _) = EditorFixture.minimalSingleClip()
        let trajectory = [
            MouseTrajectorySample(timelineTime: 4.0, centerX: 0.523, centerY: 0.487),
            MouseTrajectorySample(timelineTime: 4.5, centerX: 0.6, centerY: 0.5)
        ]
        _ = try GenerateManualZoomsCommand(
            marks: [AutoZoomClick(timelineTime: 4.0, centerX: 0.523, centerY: 0.487,
                                  source: .hotkey)],
            mouseTrajectory: trajectory
        ).apply(to: &project)
        XCTAssertEqual(project.effects.count, 1)
        XCTAssertEqual(project.effects[0].centerX, 0.523, accuracy: 1e-9)
        XCTAssertEqual(project.effects[0].centerY, 0.487, accuracy: 1e-9)
    }

    // MARK: - Zoom-keyframe non-overlap hardening (slice #11.f)

    func test_autoZoom_forcedSplit_truncatesPreviousClusterToAvoidOverlap() throws {
        var (project, _) = EditorFixture.minimalSingleClip()
        // Two clicks 1.5s apart with a spatial jump: the spatial gate forces
        // a split, but click2's zoom-in start (5.5-0.45=5.05) lands inside
        // the first cluster's tail (4.0+1.8+0.45=6.25). L2 must truncate
        // the first cluster's end to exactly click2's start so the two
        // emitted ranges are disjoint (half-open).
        let clicks = [
            AutoZoomClick(timelineTime: 4.0, centerX: 0.1, centerY: 0.1),
            AutoZoomClick(timelineTime: 5.5, centerX: 0.9, centerY: 0.9)
        ]
        _ = try GenerateAutoZoomFromClicksCommand(clicks: clicks).apply(to: &project)
        XCTAssertEqual(project.effects.count, 2)
        let sorted = project.effects.sorted { $0.timelineRange.start.seconds < $1.timelineRange.start.seconds }
        let firstEnd = sorted[0].timelineRange.end.seconds
        let secondStart = sorted[1].timelineRange.start.seconds
        XCTAssertEqual(firstEnd, secondStart, accuracy: 1e-6,
                       "forced split must leave the two clusters perfectly adjacent")
        XCTAssertFalse(sorted[0].timelineRange.overlaps(sorted[1].timelineRange),
                       "ranges must not overlap after truncation")
    }

    func test_autoZoom_forcedSplit_dropsPreviousClusterWhenTooShort() throws {
        var (project, _) = EditorFixture.minimalSingleClip()
        // Two clicks only 0.4s apart with a spatial jump. Truncation pulls
        // the first cluster's end down to 0.4s, well below the 1.25s
        // minVisibleDuration floor (just an ease-in ramp with no hold) — so
        // it gets dropped entirely rather than render as a flash.
        let clicks = [
            AutoZoomClick(timelineTime: 4.0, centerX: 0.1, centerY: 0.1),
            AutoZoomClick(timelineTime: 4.4, centerX: 0.9, centerY: 0.9)
        ]
        _ = try GenerateAutoZoomFromClicksCommand(clicks: clicks).apply(to: &project)
        XCTAssertEqual(project.effects.count, 1,
                       "first cluster too short to be visible — dropped")
        XCTAssertEqual(project.effects[0].centerX, 0.9, accuracy: 1e-9,
                       "remaining cluster comes from the second click")
    }

    func test_autoZoom_regenerate_replacesPreviousAutoKeyframes() throws {
        var (project, _) = EditorFixture.minimalSingleClip()
        // First generation with one click.
        _ = try GenerateAutoZoomFromClicksCommand(
            clicks: [AutoZoomClick(timelineTime: 3.0)]
        ).apply(to: &project)
        XCTAssertEqual(project.effects.count, 1)

        // Second generation with TWO different, widely-spaced clicks. The
        // first generation's keyframe must be replaced, not stacked on.
        _ = try GenerateAutoZoomFromClicksCommand(
            clicks: [AutoZoomClick(timelineTime: 2.0), AutoZoomClick(timelineTime: 6.0)]
        ).apply(to: &project)
        XCTAssertEqual(project.effects.count, 2, "previous auto-keyframes wiped")
    }

    func test_autoZoom_regenerate_preservesManualKeyframes() throws {
        var (project, _) = EditorFixture.minimalSingleClip()
        // Place a manual keyframe at a non-colliding position first.
        let manual = EffectKeyframe(
            kind: .zoom,
            timelineRange: TimeRange(start: .seconds(0.0), duration: .seconds(0.5)),
            origin: .manualHotkey
        )
        _ = try AddEffectKeyframeCommand(keyframe: manual).apply(to: &project)
        // Two generates back-to-back; manual must survive both.
        _ = try GenerateAutoZoomFromClicksCommand(
            clicks: [AutoZoomClick(timelineTime: 3.0)]
        ).apply(to: &project)
        _ = try GenerateAutoZoomFromClicksCommand(
            clicks: [AutoZoomClick(timelineTime: 6.0)]
        ).apply(to: &project)
        XCTAssertTrue(project.effects.contains { $0.id == manual.id },
                      "manual keyframe must survive every regenerate")
    }

    func test_autoZoom_skipsClicksThatOverlapManualKeyframe() throws {
        var (project, _) = EditorFixture.minimalSingleClip()
        // Manual keyframe spans [2.0, 4.0). A click at t=3.0 would build a
        // zoom range [2.3, 5.3) that overlaps the manual; must be dropped.
        // A click at t=6.0 (range [5.3, 8.3)) doesn't overlap; must survive.
        let manual = EffectKeyframe(
            kind: .zoom,
            timelineRange: TimeRange(start: .seconds(2.0), duration: .seconds(2.0)),
            origin: .manualHotkey
        )
        _ = try AddEffectKeyframeCommand(keyframe: manual).apply(to: &project)
        _ = try GenerateAutoZoomFromClicksCommand(
            clicks: [AutoZoomClick(timelineTime: 3.0), AutoZoomClick(timelineTime: 6.0)]
        ).apply(to: &project)
        // 1 manual + 1 auto (the t=6 click); the t=3 click was fenced out.
        XCTAssertEqual(project.effects.count, 2)
        let autoCount = project.effects.filter { $0.origin == .auto }.count
        XCTAssertEqual(autoCount, 1, "fenced click must not produce an auto keyframe")
    }

    func test_autoZoom_regenerate_undoRestoresPreviousAutoSet() throws {
        var (project, _) = EditorFixture.minimalSingleClip()
        // First generation — set A.
        _ = try GenerateAutoZoomFromClicksCommand(
            clicks: [AutoZoomClick(timelineTime: 3.0)]
        ).apply(to: &project)
        let setAIDs = Set(project.effects.map(\.id))
        XCTAssertEqual(setAIDs.count, 1)

        // Second generation — set B replaces set A.
        let inverse = try GenerateAutoZoomFromClicksCommand(
            clicks: [AutoZoomClick(timelineTime: 6.0)]
        ).apply(to: &project)
        let setBIDs = Set(project.effects.map(\.id))
        XCTAssertEqual(setBIDs.count, 1)
        XCTAssertTrue(setAIDs.intersection(setBIDs).isEmpty,
                      "regenerate produces fresh IDs")

        // Undo — set A returns, set B is removed.
        _ = try inverse.apply(to: &project)
        XCTAssertEqual(Set(project.effects.map(\.id)), setAIDs)
    }

    func test_generateManualZooms_skipsOverlappingMarks() throws {
        var (project, _) = EditorFixture.minimalSingleClip()
        // Two ⌃⌘Z presses 0.3s apart — second falls inside the first's
        // proposed range. Dedup keeps the earlier one.
        _ = try GenerateManualZoomsCommand(
            marks: [
                AutoZoomClick(timelineTime: 3.0, centerX: 0.3, centerY: 0.3),
                AutoZoomClick(timelineTime: 3.3, centerX: 0.7, centerY: 0.7)
            ]
        ).apply(to: &project)
        XCTAssertEqual(project.effects.count, 1, "second mark overlaps first — dedup'd")
        XCTAssertEqual(project.effects[0].centerX, 0.3, accuracy: 1e-9,
                       "first (earlier) mark wins")
    }

    func test_generateManualZooms_skipsMarksThatOverlapAutoKeyframes() throws {
        var (project, _) = EditorFixture.minimalSingleClip()
        // Seed an auto keyframe via the command path.
        _ = try GenerateAutoZoomFromClicksCommand(
            clicks: [AutoZoomClick(timelineTime: 3.0, centerX: 0.5, centerY: 0.5)]
        ).apply(to: &project)
        XCTAssertEqual(project.effects.count, 1)
        let autoRange = project.effects[0].timelineRange  // [2.3, 5.3)

        // A mark inside the auto range gets skipped; a mark outside survives.
        // Auto range duration = 0.7 + 1.8 + 0.5 = 3.0; mark at t=4.0 → range
        // [3.3, 6.3) overlaps. Mark at t=7.0 → range [6.3, 9.3) is adjacent
        // OR disjoint depending on auto endpoint — pick 7.5 to be safe (range
        // [6.8, 9.8)).
        _ = try GenerateManualZoomsCommand(
            marks: [
                AutoZoomClick(timelineTime: 4.0, centerX: 0.1, centerY: 0.1),
                AutoZoomClick(timelineTime: 7.5, centerX: 0.9, centerY: 0.9)
            ]
        ).apply(to: &project)
        // 1 auto + 1 manual (the t=7.5 mark).
        XCTAssertEqual(project.effects.count, 2)
        let manualCount = project.effects.filter { $0.origin == .manualHotkey }.count
        XCTAssertEqual(manualCount, 1,
                       "mark overlapping the auto keyframe must be dropped")
        // Sanity: auto range still intact.
        XCTAssertTrue(project.effects.contains { $0.timelineRange == autoRange })
    }
}
