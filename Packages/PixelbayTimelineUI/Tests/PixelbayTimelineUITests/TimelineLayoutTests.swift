import CoreGraphics
import PixelbayCore
@testable import PixelbayTimelineUI
import XCTest

final class TimelineLayoutTests: XCTestCase {
    func test_emptyProject_hasNoTracks_andZeroContentWidth() {
        let project = Project(name: "Empty")
        let viewport = TimelineViewport(
            size: CGSize(width: 800, height: 240),
            pixelsPerSecond: 80
        )
        let layout = TimelineLayoutCalculator.layout(project: project, viewport: viewport)
        XCTAssertEqual(layout.tracks.count, 0)
        // Content width still spans at least the viewport's lane area
        // (header width + remaining viewport width).
        XCTAssertEqual(layout.totalContentWidth, 800)
    }

    func test_singleClipProject_emitsOneTrack_andOneClipFrame() {
        let project = makeSingleClipProject(durationSeconds: 5)
        let viewport = TimelineViewport(size: CGSize(width: 1000, height: 240), pixelsPerSecond: 100)
        let layout = TimelineLayoutCalculator.layout(project: project, viewport: viewport)
        XCTAssertEqual(layout.tracks.count, 1)
        let track = layout.tracks[0]
        XCTAssertEqual(track.clips.count, 1)
        let clip = track.clips[0]
        // Clip starts at timeline 0 → x = trackHeaderWidth (140) + 0
        XCTAssertEqual(clip.frame.origin.x, TimelineLayoutCalculator.trackHeaderWidth, accuracy: 0.001)
        // Width = 5s * 100pt/s = 500pt
        XCTAssertEqual(clip.frame.size.width, 500, accuracy: 0.001)
    }

    func test_zoomChange_scalesClipWidth() {
        let project = makeSingleClipProject(durationSeconds: 4)
        let zoomedOut = TimelineLayoutCalculator.layout(
            project: project,
            viewport: TimelineViewport(size: CGSize(width: 800, height: 240), pixelsPerSecond: 50)
        )
        let zoomedIn = TimelineLayoutCalculator.layout(
            project: project,
            viewport: TimelineViewport(size: CGSize(width: 800, height: 240), pixelsPerSecond: 200)
        )
        XCTAssertEqual(zoomedOut.tracks[0].clips[0].frame.size.width, 200, accuracy: 0.001)
        XCTAssertEqual(zoomedIn.tracks[0].clips[0].frame.size.width, 800, accuracy: 0.001)
    }

    func test_pixelsPerSecond_clampsAtBounds() {
        let project = makeSingleClipProject(durationSeconds: 1)
        let belowMin = TimelineLayoutCalculator.layout(
            project: project,
            viewport: TimelineViewport(size: CGSize(width: 800, height: 240), pixelsPerSecond: 1)
        )
        let aboveMax = TimelineLayoutCalculator.layout(
            project: project,
            viewport: TimelineViewport(size: CGSize(width: 800, height: 240), pixelsPerSecond: 99999)
        )
        XCTAssertEqual(belowMin.tracks[0].clips[0].frame.size.width, TimelineLayoutCalculator.minPixelsPerSecond, accuracy: 0.001)
        XCTAssertEqual(aboveMax.tracks[0].clips[0].frame.size.width, TimelineLayoutCalculator.maxPixelsPerSecond, accuracy: 0.001)
    }

    func test_scrollOffset_shiftsClipFrames_left() {
        let project = makeSingleClipProject(durationSeconds: 4, startSeconds: 2)
        // Without scroll: clip starts at timeline 2s → x = headerWidth + 2*100 = 340
        let noScroll = TimelineLayoutCalculator.layout(
            project: project,
            viewport: TimelineViewport(size: CGSize(width: 1000, height: 240), pixelsPerSecond: 100, scrollX: 0)
        )
        XCTAssertEqual(noScroll.tracks[0].clips[0].frame.origin.x,
                       TimelineLayoutCalculator.trackHeaderWidth + 200,
                       accuracy: 0.001)
        // Scroll right by 1s → x decreases by 100pt
        let scrolled = TimelineLayoutCalculator.layout(
            project: project,
            viewport: TimelineViewport(size: CGSize(width: 1000, height: 240), pixelsPerSecond: 100, scrollX: 1)
        )
        XCTAssertEqual(scrolled.tracks[0].clips[0].frame.origin.x,
                       TimelineLayoutCalculator.trackHeaderWidth + 100,
                       accuracy: 0.001)
    }

    func test_multipleTracks_areVerticallyStacked() {
        var project = makeTwoTrackProject()
        // Branch B (2026-05-27): with the smart-default collapsed seed,
        // grouped tracks share a row. Force-expand the video group so
        // this test still exercises the per-physical-track stacking math.
        project.timelineLaneCollapse = [.video: false, .audio: false]
        let layout = TimelineLayoutCalculator.layout(
            project: project,
            viewport: TimelineViewport(size: CGSize(width: 800, height: 240), pixelsPerSecond: 80)
        )
        let track0 = layout.tracks[0]
        let track1 = layout.tracks[1]
        // Track 1's y should be track 0's y + trackHeight + spacing
        let expectedDelta = TimelineLayoutCalculator.defaultTrackHeight + TimelineLayoutCalculator.trackSpacing
        XCTAssertEqual(track1.headerFrame.origin.y - track0.headerFrame.origin.y,
                       expectedDelta, accuracy: 0.001)
    }

    func test_multipleTracks_areCollapsedByDefault_shareSameRow() {
        // Branch B (2026-05-27): the smart-default seed collapses both
        // groups. Two video tracks (screen + cam) share the same Y when
        // the project is fresh.
        let project = makeTwoTrackProject()
        let layout = TimelineLayoutCalculator.layout(
            project: project,
            viewport: TimelineViewport(size: CGSize(width: 800, height: 240), pixelsPerSecond: 80)
        )
        XCTAssertEqual(layout.tracks[0].headerFrame.origin.y,
                       layout.tracks[1].headerFrame.origin.y,
                       accuracy: 0.001,
                       "grouped collapsed tracks share a single row")
    }

    func test_totalContentHeight_grows_withTrackCount() {
        // Branch B: with grouped collapse, both the single-track project
        // and the two-track project still emit the same row count (one
        // video lane + effects). Force-expand the video lane on the
        // two-track project so it actually emits two rows.
        var twoTrack = makeTwoTrackProject()
        twoTrack.timelineLaneCollapse = [.video: false]
        let single = TimelineLayoutCalculator.layout(
            project: makeSingleClipProject(durationSeconds: 1),
            viewport: TimelineViewport(size: CGSize(width: 400, height: 240), pixelsPerSecond: 80)
        )
        let two = TimelineLayoutCalculator.layout(
            project: twoTrack,
            viewport: TimelineViewport(size: CGSize(width: 400, height: 240), pixelsPerSecond: 80)
        )
        XCTAssertGreaterThan(two.totalContentHeight, single.totalContentHeight)
    }

    func test_totalSeconds_isMaxOfClipEndsAcrossTracks() {
        let project = makeTwoTrackProject()
        // Track 0 has clip ending at 5s; track 1 has clip 2..6s → total = 6
        XCTAssertEqual(TimelineLayoutCalculator.totalSeconds(in: project), 6, accuracy: 0.001)
    }

    // MARK: - Hit-test

    func test_hitTest_inRulerStrip_returnsRuler() {
        let project = makeSingleClipProject(durationSeconds: 1)
        let layout = TimelineLayoutCalculator.layout(
            project: project,
            viewport: TimelineViewport(size: CGSize(width: 800, height: 240), pixelsPerSecond: 80)
        )
        let hit = TimelineHitTest.hit(at: CGPoint(x: 200, y: 5), in: layout)
        XCTAssertEqual(hit, .ruler)
    }

    func test_hitTest_onClipBody_returnsClipBody() {
        let project = makeSingleClipProject(durationSeconds: 5)
        let trackID = project.tracks[0].id
        let clipID = project.tracks[0].clips[0].id
        let layout = TimelineLayoutCalculator.layout(
            project: project,
            viewport: TimelineViewport(size: CGSize(width: 1000, height: 240), pixelsPerSecond: 100)
        )
        let clipFrame = layout.tracks[0].clips[0].frame
        let hit = TimelineHitTest.hit(at: CGPoint(x: clipFrame.midX, y: clipFrame.midY), in: layout)
        XCTAssertEqual(hit, .clipBody(clipID, trackID))
    }

    func test_hitTest_onClipLeftEdge_returnsClipLeftEdge() {
        let project = makeSingleClipProject(durationSeconds: 5)
        let trackID = project.tracks[0].id
        let clipID = project.tracks[0].clips[0].id
        let layout = TimelineLayoutCalculator.layout(
            project: project,
            viewport: TimelineViewport(size: CGSize(width: 1000, height: 240), pixelsPerSecond: 100)
        )
        let clipFrame = layout.tracks[0].clips[0].frame
        // 2pt inset from left edge — well within the 6pt edge zone.
        let hit = TimelineHitTest.hit(
            at: CGPoint(x: clipFrame.minX + 2, y: clipFrame.midY),
            in: layout
        )
        XCTAssertEqual(hit, .clipLeftEdge(clipID, trackID))
    }

    func test_hitTest_onClipRightEdge_returnsClipRightEdge() {
        let project = makeSingleClipProject(durationSeconds: 5)
        let trackID = project.tracks[0].id
        let clipID = project.tracks[0].clips[0].id
        let layout = TimelineLayoutCalculator.layout(
            project: project,
            viewport: TimelineViewport(size: CGSize(width: 1000, height: 240), pixelsPerSecond: 100)
        )
        let clipFrame = layout.tracks[0].clips[0].frame
        let hit = TimelineHitTest.hit(
            at: CGPoint(x: clipFrame.maxX - 2, y: clipFrame.midY),
            in: layout
        )
        XCTAssertEqual(hit, .clipRightEdge(clipID, trackID))
    }

    func test_hitTest_narrowClip_treatsWholeClipAsBody() {
        // pixelsPerSecond = 100, durationSeconds = 0.1 → 10pt-wide clip.
        // 10pt < edgeZoneWidth * 3 (18pt), so the entire clip is body.
        let project = makeSingleClipProject(durationSeconds: 0.1)
        let trackID = project.tracks[0].id
        let clipID = project.tracks[0].clips[0].id
        let layout = TimelineLayoutCalculator.layout(
            project: project,
            viewport: TimelineViewport(size: CGSize(width: 1000, height: 240), pixelsPerSecond: 100)
        )
        let clipFrame = layout.tracks[0].clips[0].frame
        let hit = TimelineHitTest.hit(at: CGPoint(x: clipFrame.minX + 1, y: clipFrame.midY), in: layout)
        XCTAssertEqual(hit, .clipBody(clipID, trackID))
    }

    func test_hitTest_onTrackHeader_returnsTrackHeader() {
        let project = makeSingleClipProject(durationSeconds: 5)
        let trackID = project.tracks[0].id
        let layout = TimelineLayoutCalculator.layout(
            project: project,
            viewport: TimelineViewport(size: CGSize(width: 1000, height: 240), pixelsPerSecond: 100)
        )
        let header = layout.tracks[0].headerFrame
        let hit = TimelineHitTest.hit(at: CGPoint(x: header.midX, y: header.midY), in: layout)
        XCTAssertEqual(hit, .trackHeader(trackID))
    }

    func test_hitTest_inEmptyLane_returnsEmptyLane() {
        // Single-clip project with the clip ending at 2s. Click at 4s →
        // empty lane.
        let project = makeSingleClipProject(durationSeconds: 2)
        let trackID = project.tracks[0].id
        let layout = TimelineLayoutCalculator.layout(
            project: project,
            viewport: TimelineViewport(size: CGSize(width: 1000, height: 240), pixelsPerSecond: 100)
        )
        let lane = layout.tracks[0].laneFrame
        // Move past the clip's right edge.
        let pastClipX = layout.tracks[0].clips[0].frame.maxX + 50
        XCTAssertLessThan(pastClipX, lane.maxX)
        let hit = TimelineHitTest.hit(at: CGPoint(x: pastClipX, y: lane.midY), in: layout)
        XCTAssertEqual(hit, .emptyLane(trackID))
    }

    // MARK: - timelineSeconds(forViewportX:viewport:)

    func test_timelineSeconds_atHeaderEdge_isZero() {
        let viewport = TimelineViewport(size: CGSize(width: 800, height: 240), pixelsPerSecond: 100)
        let secs = TimelineLayoutCalculator.timelineSeconds(
            forViewportX: TimelineLayoutCalculator.trackHeaderWidth,
            viewport: viewport
        )
        XCTAssertEqual(secs, 0, accuracy: 0.001)
    }

    func test_timelineSeconds_inHeaderColumn_clampsToZero() {
        // Click in the header column maps to negative timeline; clamp to 0.
        let viewport = TimelineViewport(size: CGSize(width: 800, height: 240), pixelsPerSecond: 100)
        let secs = TimelineLayoutCalculator.timelineSeconds(forViewportX: 20, viewport: viewport)
        XCTAssertEqual(secs, 0, accuracy: 0.001)
    }

    func test_timelineSeconds_inLane_dividesByPps() {
        let viewport = TimelineViewport(size: CGSize(width: 800, height: 240), pixelsPerSecond: 100)
        let x = TimelineLayoutCalculator.trackHeaderWidth + 250
        let secs = TimelineLayoutCalculator.timelineSeconds(forViewportX: x, viewport: viewport)
        XCTAssertEqual(secs, 2.5, accuracy: 0.001)
    }

    func test_timelineSeconds_appliesScrollOffset() {
        let viewport = TimelineViewport(size: CGSize(width: 800, height: 240), pixelsPerSecond: 100, scrollX: 1)
        let x = TimelineLayoutCalculator.trackHeaderWidth + 200
        let secs = TimelineLayoutCalculator.timelineSeconds(forViewportX: x, viewport: viewport)
        XCTAssertEqual(secs, 3.0, accuracy: 0.001)
    }

    func test_timelineSeconds_clampsPpsAtBounds() {
        let viewport = TimelineViewport(size: CGSize(width: 800, height: 240), pixelsPerSecond: 99999)
        let x = TimelineLayoutCalculator.trackHeaderWidth + TimelineLayoutCalculator.maxPixelsPerSecond
        let secs = TimelineLayoutCalculator.timelineSeconds(forViewportX: x, viewport: viewport)
        XCTAssertEqual(secs, 1.0, accuracy: 0.001)
    }

    // MARK: - viewportX(forTimelineSeconds:viewport:)

    func test_viewportX_atTimeZero_isHeaderEdge() {
        let viewport = TimelineViewport(size: CGSize(width: 800, height: 240), pixelsPerSecond: 100)
        let x = TimelineLayoutCalculator.viewportX(forTimelineSeconds: 0, viewport: viewport)
        XCTAssertEqual(x, TimelineLayoutCalculator.trackHeaderWidth, accuracy: 0.001)
    }

    func test_viewportX_offsetsByPps() {
        let viewport = TimelineViewport(size: CGSize(width: 800, height: 240), pixelsPerSecond: 100)
        let x = TimelineLayoutCalculator.viewportX(forTimelineSeconds: 2.5, viewport: viewport)
        XCTAssertEqual(x, TimelineLayoutCalculator.trackHeaderWidth + 250, accuracy: 0.001)
    }

    func test_viewportX_appliesScrollOffset() {
        // scrollX = 1s → playhead at t=2 lands 1s past the header.
        let viewport = TimelineViewport(size: CGSize(width: 800, height: 240), pixelsPerSecond: 100, scrollX: 1)
        let x = TimelineLayoutCalculator.viewportX(forTimelineSeconds: 2, viewport: viewport)
        XCTAssertEqual(x, TimelineLayoutCalculator.trackHeaderWidth + 100, accuracy: 0.001)
    }

    func test_viewportX_isInverseOfTimelineSeconds() {
        // Round-trip: x → seconds → x should land back where we started
        // (within rounding) for points inside the lane.
        let viewport = TimelineViewport(size: CGSize(width: 800, height: 240), pixelsPerSecond: 80, scrollX: 0.5)
        let originalX: CGFloat = TimelineLayoutCalculator.trackHeaderWidth + 333
        let secs = TimelineLayoutCalculator.timelineSeconds(forViewportX: originalX, viewport: viewport)
        let xAgain = TimelineLayoutCalculator.viewportX(forTimelineSeconds: secs, viewport: viewport)
        XCTAssertEqual(originalX, xAgain, accuracy: 0.001)
    }

    func test_viewportX_clampsPpsAtBounds() {
        // pps above maxPixelsPerSecond is clamped — same behaviour as the
        // forward mapper, so the playhead stays in sync with the clip
        // frames at the boundary zoom.
        let viewport = TimelineViewport(size: CGSize(width: 800, height: 240), pixelsPerSecond: 99999)
        let x = TimelineLayoutCalculator.viewportX(forTimelineSeconds: 1, viewport: viewport)
        XCTAssertEqual(x,
                       TimelineLayoutCalculator.trackHeaderWidth + TimelineLayoutCalculator.maxPixelsPerSecond,
                       accuracy: 0.001)
    }

    // MARK: - trackHeight

    func test_trackHeight_default_is56pt() {
        let project = makeSingleClipProject(durationSeconds: 5)
        let layout = TimelineLayoutCalculator.layout(
            project: project,
            viewport: TimelineViewport(size: CGSize(width: 1000, height: 240), pixelsPerSecond: 100)
        )
        XCTAssertEqual(layout.tracks[0].headerFrame.height,
                       TimelineLayoutCalculator.defaultTrackHeight,
                       accuracy: 0.001)
    }

    func test_trackHeight_propagatesFromViewport_toClipFrames() {
        let project = makeSingleClipProject(durationSeconds: 5)
        let layout = TimelineLayoutCalculator.layout(
            project: project,
            viewport: TimelineViewport(
                size: CGSize(width: 1000, height: 240),
                pixelsPerSecond: 100,
                trackHeight: 32
            )
        )
        XCTAssertEqual(layout.tracks[0].clips[0].frame.height, 32, accuracy: 0.001)
        XCTAssertEqual(layout.tracks[0].headerFrame.height, 32, accuracy: 0.001)
    }

    func test_trackHeight_clampsAtBounds() {
        let project = makeSingleClipProject(durationSeconds: 1)
        let belowMin = TimelineLayoutCalculator.layout(
            project: project,
            viewport: TimelineViewport(
                size: CGSize(width: 600, height: 240),
                pixelsPerSecond: 80,
                trackHeight: 4
            )
        )
        let aboveMax = TimelineLayoutCalculator.layout(
            project: project,
            viewport: TimelineViewport(
                size: CGSize(width: 600, height: 240),
                pixelsPerSecond: 80,
                trackHeight: 9999
            )
        )
        XCTAssertEqual(belowMin.tracks[0].headerFrame.height,
                       TimelineLayoutCalculator.minTrackHeight, accuracy: 0.001)
        XCTAssertEqual(aboveMax.tracks[0].headerFrame.height,
                       TimelineLayoutCalculator.maxTrackHeight, accuracy: 0.001)
    }

    // MARK: - niceTickInterval

    func test_niceTickInterval_atDefaultZoom_isOneSecondMajor() {
        // pps=80: 1s × 80pt = 80pt — fits the 60pt min major-label budget.
        let intervals = TimelineLayoutCalculator.niceTickInterval(forPixelsPerSecond: 80)
        XCTAssertEqual(intervals.major, 1, accuracy: 0.0001)
        // Minor must be smaller than major and at least 6pt wide.
        XCTAssertLessThan(intervals.minor, intervals.major)
        XCTAssertGreaterThanOrEqual(80 * intervals.minor, 6)
    }

    func test_niceTickInterval_atZoomedOut_picksLargerMajor() {
        // pps=16: 1s only 16pt → too narrow; 5s = 80pt is the first that fits.
        let intervals = TimelineLayoutCalculator.niceTickInterval(forPixelsPerSecond: 16)
        XCTAssertEqual(intervals.major, 5, accuracy: 0.0001)
    }

    func test_niceTickInterval_atZoomedIn_picksSubsecondMinor() {
        // pps=400: 1s = 400pt; minor should drop below 1s.
        let intervals = TimelineLayoutCalculator.niceTickInterval(forPixelsPerSecond: 400)
        XCTAssertLessThanOrEqual(intervals.major, 1)
        XCTAssertLessThan(intervals.minor, 1)
    }

    func test_niceTickInterval_clampsPpsAtBounds() {
        // Above-max pps clamps; the interval should match the max-clamp value.
        let aboveMax = TimelineLayoutCalculator.niceTickInterval(forPixelsPerSecond: 99999)
        let atMax = TimelineLayoutCalculator.niceTickInterval(
            forPixelsPerSecond: TimelineLayoutCalculator.maxPixelsPerSecond
        )
        XCTAssertEqual(aboveMax.major, atMax.major, accuracy: 0.0001)
        XCTAssertEqual(aboveMax.minor, atMax.minor, accuracy: 0.0001)
    }

    func test_niceTickInterval_minorMatchesMajorWhenSubdivisionTooNarrow() {
        // At the minimum pps, even the next-smaller candidate doesn't clear
        // the 6pt min minor width — so minor collapses into major.
        let intervals = TimelineLayoutCalculator.niceTickInterval(
            forPixelsPerSecond: TimelineLayoutCalculator.minPixelsPerSecond
        )
        // Either minor is strictly less than major and ≥ 6pt wide, or it
        // collapses into major. Both are acceptable; the contract is no
        // < 6pt minor ticks render.
        if intervals.minor < intervals.major {
            XCTAssertGreaterThanOrEqual(
                Double(TimelineLayoutCalculator.minPixelsPerSecond) * intervals.minor, 6
            )
        } else {
            XCTAssertEqual(intervals.minor, intervals.major, accuracy: 0.0001)
        }
    }

    // MARK: - effectsLane

    func test_effectsLane_emptyEffects_emitsHeaderAndLane_belowAllTracks() {
        let project = makeSingleClipProject(durationSeconds: 5)
        let layout = TimelineLayoutCalculator.layout(
            project: project,
            viewport: TimelineViewport(size: CGSize(width: 1000, height: 240), pixelsPerSecond: 100)
        )
        XCTAssertEqual(layout.effectsLane.keyframes.count, 0)
        XCTAssertEqual(layout.effectsLane.headerFrame.height,
                       TimelineLayoutCalculator.effectsLaneHeight, accuracy: 0.001)
        XCTAssertEqual(layout.effectsLane.headerFrame.width,
                       TimelineLayoutCalculator.trackHeaderWidth, accuracy: 0.001)
        let lastTrack = layout.tracks.last!
        XCTAssertGreaterThanOrEqual(layout.effectsLane.headerFrame.minY, lastTrack.headerFrame.maxY)
        XCTAssertEqual(layout.effectsLane.laneFrame.height,
                       TimelineLayoutCalculator.effectsLaneHeight, accuracy: 0.001)
        XCTAssertEqual(layout.effectsLane.laneFrame.minX,
                       TimelineLayoutCalculator.trackHeaderWidth, accuracy: 0.001)
    }

    func test_effectsLane_emptyProject_stillEmitsLane() {
        let project = Project(name: "Empty")
        let layout = TimelineLayoutCalculator.layout(
            project: project,
            viewport: TimelineViewport(size: CGSize(width: 800, height: 240), pixelsPerSecond: 80)
        )
        XCTAssertEqual(layout.effectsLane.keyframes.count, 0)
        // Header sits right after ruler + verticalInset since there are no tracks.
        XCTAssertEqual(layout.effectsLane.headerFrame.minY,
                       TimelineLayoutCalculator.rulerHeight + TimelineLayoutCalculator.verticalInset,
                       accuracy: 0.001)
    }

    func test_effectsLane_singleZoomKeyframe_mapsTimeRangeToFrame() {
        var project = makeSingleClipProject(durationSeconds: 5)
        let kf = EffectKeyframe(
            kind: .zoom,
            timelineRange: TimeRange(start: rt(1), duration: rt(2))
        )
        project.effects = [kf]
        let layout = TimelineLayoutCalculator.layout(
            project: project,
            viewport: TimelineViewport(size: CGSize(width: 1000, height: 240), pixelsPerSecond: 100)
        )
        XCTAssertEqual(layout.effectsLane.keyframes.count, 1)
        let kfLayout = layout.effectsLane.keyframes[0]
        XCTAssertEqual(kfLayout.id, kf.id)
        XCTAssertEqual(kfLayout.kind, .zoom)
        // start=1s → headerWidth + 100; duration=2s → 200pt wide.
        XCTAssertEqual(kfLayout.frame.origin.x,
                       TimelineLayoutCalculator.trackHeaderWidth + 100, accuracy: 0.001)
        XCTAssertEqual(kfLayout.frame.size.width, 200, accuracy: 0.001)
        XCTAssertEqual(kfLayout.frame.size.height,
                       TimelineLayoutCalculator.effectsLaneHeight, accuracy: 0.001)
        XCTAssertEqual(kfLayout.frame.origin.y, layout.effectsLane.laneFrame.minY, accuracy: 0.001)
    }

    func test_effectsLane_preservesKindAndOrder() {
        var project = makeSingleClipProject(durationSeconds: 10)
        let zoom = EffectKeyframe(
            kind: .zoom,
            timelineRange: TimeRange(start: rt(1), duration: rt(2))
        )
        let swap = EffectKeyframe(
            kind: .talkingHeadSwap,
            timelineRange: TimeRange(start: rt(4), duration: rt(2))
        )
        project.effects = [zoom, swap]
        let layout = TimelineLayoutCalculator.layout(
            project: project,
            viewport: TimelineViewport(size: CGSize(width: 1200, height: 240), pixelsPerSecond: 100)
        )
        XCTAssertEqual(layout.effectsLane.keyframes.map(\.kind), [.zoom, .talkingHeadSwap])
        XCTAssertEqual(layout.effectsLane.keyframes.map(\.id), [zoom.id, swap.id])
    }

    func test_effectsLane_propagatesOriginFromKeyframeToLayout() {
        var project = makeSingleClipProject(durationSeconds: 10)
        let autoKF = EffectKeyframe(
            kind: .zoom,
            timelineRange: TimeRange(start: rt(1), duration: rt(2)),
            origin: .auto
        )
        let manualKF = EffectKeyframe(
            kind: .zoom,
            timelineRange: TimeRange(start: rt(4), duration: rt(2)),
            origin: .manualHotkey
        )
        project.effects = [autoKF, manualKF]
        let layout = TimelineLayoutCalculator.layout(
            project: project,
            viewport: TimelineViewport(size: CGSize(width: 1200, height: 240), pixelsPerSecond: 100)
        )
        XCTAssertEqual(layout.effectsLane.keyframes[0].origin, .auto)
        XCTAssertEqual(layout.effectsLane.keyframes[1].origin, .manualHotkey)
    }

    func test_effectsLane_appliesScrollOffset() {
        var project = makeSingleClipProject(durationSeconds: 10)
        project.effects = [EffectKeyframe(
            kind: .zoom,
            timelineRange: TimeRange(start: rt(3), duration: rt(2))
        )]
        let layout = TimelineLayoutCalculator.layout(
            project: project,
            viewport: TimelineViewport(size: CGSize(width: 1000, height: 240), pixelsPerSecond: 100, scrollX: 1)
        )
        // Without scroll, x = headerWidth + 300; scroll by 1s → -100pt.
        XCTAssertEqual(layout.effectsLane.keyframes[0].frame.origin.x,
                       TimelineLayoutCalculator.trackHeaderWidth + 200, accuracy: 0.001)
    }

    func test_effectsLane_zoomChange_scalesKeyframeWidth() {
        var project = makeSingleClipProject(durationSeconds: 10)
        project.effects = [EffectKeyframe(
            kind: .zoom,
            timelineRange: TimeRange(start: rt(0), duration: rt(4))
        )]
        let zoomedOut = TimelineLayoutCalculator.layout(
            project: project,
            viewport: TimelineViewport(size: CGSize(width: 800, height: 240), pixelsPerSecond: 50)
        )
        let zoomedIn = TimelineLayoutCalculator.layout(
            project: project,
            viewport: TimelineViewport(size: CGSize(width: 800, height: 240), pixelsPerSecond: 200)
        )
        XCTAssertEqual(zoomedOut.effectsLane.keyframes[0].frame.size.width, 200, accuracy: 0.001)
        XCTAssertEqual(zoomedIn.effectsLane.keyframes[0].frame.size.width, 800, accuracy: 0.001)
    }

    func test_effectsLane_contentHeight_growsByLaneHeight() {
        // With effects lane always present, content height grows by
        // (effectsLaneHeight + trackSpacing) compared to a hypothetical
        // lane-less layout. The simplest stable check is that contentSize
        // matches the layout's totalContentHeight for the same inputs.
        let project = makeSingleClipProject(durationSeconds: 1)
        let layout = TimelineLayoutCalculator.layout(
            project: project,
            viewport: TimelineViewport(size: CGSize(width: 400, height: 240), pixelsPerSecond: 80)
        )
        let cs = TimelineLayoutCalculator.contentSize(
            for: project,
            pixelsPerSecond: 80,
            trackHeight: TimelineLayoutCalculator.defaultTrackHeight
        )
        XCTAssertEqual(layout.totalContentHeight, cs.height, accuracy: 0.001)
        // And the effects lane bottom must be inside the content.
        XCTAssertLessThanOrEqual(layout.effectsLane.laneFrame.maxY, layout.totalContentHeight)
    }

    func test_hitTest_belowAllTracks_returnsEmpty() {
        let project = makeSingleClipProject(durationSeconds: 5)
        let layout = TimelineLayoutCalculator.layout(
            project: project,
            viewport: TimelineViewport(size: CGSize(width: 1000, height: 240), pixelsPerSecond: 100)
        )
        // Click far below the effects lane (well outside all rows) → empty.
        let bottom = layout.effectsLane.laneFrame.maxY
        let hit = TimelineHitTest.hit(at: CGPoint(x: 200, y: bottom + 200), in: layout)
        XCTAssertEqual(hit, .empty)
    }

    // MARK: - Effects-lane hit-tests

    func test_hitTest_onEffectKeyframeBody_returnsBody() {
        let project = makeProjectWithKeyframe(start: 1, duration: 3)
        let kfID = project.effects[0].id
        let layout = TimelineLayoutCalculator.layout(
            project: project,
            viewport: TimelineViewport(size: CGSize(width: 1000, height: 240), pixelsPerSecond: 100)
        )
        let kfFrame = layout.effectsLane.keyframes[0].frame
        let hit = TimelineHitTest.hit(at: CGPoint(x: kfFrame.midX, y: kfFrame.midY), in: layout)
        XCTAssertEqual(hit, .effectKeyframeBody(kfID))
    }

    func test_hitTest_onEffectKeyframeLeftEdge_returnsLeftEdge() {
        let project = makeProjectWithKeyframe(start: 1, duration: 3)
        let kfID = project.effects[0].id
        let layout = TimelineLayoutCalculator.layout(
            project: project,
            viewport: TimelineViewport(size: CGSize(width: 1000, height: 240), pixelsPerSecond: 100)
        )
        let kfFrame = layout.effectsLane.keyframes[0].frame
        let hit = TimelineHitTest.hit(at: CGPoint(x: kfFrame.minX + 2, y: kfFrame.midY), in: layout)
        XCTAssertEqual(hit, .effectKeyframeLeftEdge(kfID))
    }

    func test_hitTest_onEffectKeyframeRightEdge_returnsRightEdge() {
        let project = makeProjectWithKeyframe(start: 1, duration: 3)
        let kfID = project.effects[0].id
        let layout = TimelineLayoutCalculator.layout(
            project: project,
            viewport: TimelineViewport(size: CGSize(width: 1000, height: 240), pixelsPerSecond: 100)
        )
        let kfFrame = layout.effectsLane.keyframes[0].frame
        let hit = TimelineHitTest.hit(at: CGPoint(x: kfFrame.maxX - 2, y: kfFrame.midY), in: layout)
        XCTAssertEqual(hit, .effectKeyframeRightEdge(kfID))
    }

    func test_hitTest_onEmptyEffectsLane_returnsEmptyEffectsLane() {
        let project = makeProjectWithKeyframe(start: 1, duration: 1)
        let layout = TimelineLayoutCalculator.layout(
            project: project,
            viewport: TimelineViewport(size: CGSize(width: 1000, height: 240), pixelsPerSecond: 100)
        )
        let lane = layout.effectsLane.laneFrame
        let kfMaxX = layout.effectsLane.keyframes[0].frame.maxX
        // Click well to the right of the only keyframe but still inside the lane.
        let xPast = kfMaxX + 30
        XCTAssertLessThan(xPast, lane.maxX)
        let hit = TimelineHitTest.hit(at: CGPoint(x: xPast, y: lane.midY), in: layout)
        XCTAssertEqual(hit, .emptyEffectsLane)
    }

    func test_hitTest_onEffectsLaneHeader_returnsHeader() {
        let project = makeSingleClipProject(durationSeconds: 5)
        let layout = TimelineLayoutCalculator.layout(
            project: project,
            viewport: TimelineViewport(size: CGSize(width: 1000, height: 240), pixelsPerSecond: 100)
        )
        let header = layout.effectsLane.headerFrame
        let hit = TimelineHitTest.hit(at: CGPoint(x: header.midX, y: header.midY), in: layout)
        XCTAssertEqual(hit, .effectsLaneHeader)
    }

    func test_hitTest_narrowEffectKeyframe_treatsWholeAsBody() {
        // 50ms keyframe at 100pps → 5pt wide; under the 18pt edge-zone-trio.
        let project = makeProjectWithKeyframe(start: 1, duration: 0.05)
        let kfID = project.effects[0].id
        let layout = TimelineLayoutCalculator.layout(
            project: project,
            viewport: TimelineViewport(size: CGSize(width: 1000, height: 240), pixelsPerSecond: 100)
        )
        let kfFrame = layout.effectsLane.keyframes[0].frame
        let hit = TimelineHitTest.hit(at: CGPoint(x: kfFrame.minX + 1, y: kfFrame.midY), in: layout)
        XCTAssertEqual(hit, .effectKeyframeBody(kfID))
    }

    // MARK: - Strict snap at timeline-start (t = 0)

    func test_moveClipPreview_clampsAtTimelineStart() {
        // Clip starts at 2s. At pps=100 the lane-x for t=0 is
        // trackHeaderWidth (140). A leftward drag of 500px (= 5s, well
        // past the 2s start) must clamp the preview at xAbs = 140.
        let project = makeSingleClipProject(durationSeconds: 3, startSeconds: 2)
        let clipID = project.tracks[0].clips[0].id
        let layout = TimelineLayoutCalculator.layout(
            project: project,
            viewport: TimelineViewport(size: CGSize(width: 1000, height: 240), pixelsPerSecond: 100),
            dragPreview: .moveClip(clipID, deltaPixels: -500)
        )
        let clipFrame = layout.tracks[0].clips[0].frame
        XCTAssertEqual(clipFrame.origin.x, TimelineLayoutCalculator.trackHeaderWidth, accuracy: 0.001)
    }

    func test_moveClipPreview_allowsValidLeftDrag() {
        // Same setup; drag by exactly -100px (1s) — clip should land at
        // start=1s → xAbs = 140 + (1 * 100) = 240.
        let project = makeSingleClipProject(durationSeconds: 3, startSeconds: 2)
        let clipID = project.tracks[0].clips[0].id
        let layout = TimelineLayoutCalculator.layout(
            project: project,
            viewport: TimelineViewport(size: CGSize(width: 1000, height: 240), pixelsPerSecond: 100),
            dragPreview: .moveClip(clipID, deltaPixels: -100)
        )
        XCTAssertEqual(
            layout.tracks[0].clips[0].frame.origin.x,
            TimelineLayoutCalculator.trackHeaderWidth + 100,
            accuracy: 0.001
        )
    }

    // MARK: - Decouple-on-expand (laneBreakout, polish 2026-05-27)

    func test_computeDisplayRows_brokenOutTrack_emitsStandaloneRow() {
        // Two video tracks (screen + cam). Lane collapsed by default.
        // Break out the webcam — expect: collapsed video group row
        // (screen only) + standalone webcam row right after, then
        // effects lane.
        var project = makeTwoTrackProject()
        project.timelineLaneCollapse = [.video: true]
        if let idx = project.tracks.firstIndex(where: { $0.kind == .webcam }) {
            project.tracks[idx].laneBreakout = true
        }
        let rows = TimelineLayoutCalculator.computeDisplayRows(project: project)
        // Row 0: groupedVideo (collapsed, single member: screen only).
        guard case .groupedVideo(let groupTracks, _) = rows[0].kind else {
            return XCTFail("expected groupedVideo row first")
        }
        XCTAssertEqual(groupTracks.count, 1, "webcam excluded from group bucket")
        // Row 1: singleTrack for the broken-out webcam.
        guard case .singleTrack(_, let parentGroup) = rows[1].kind else {
            return XCTFail("expected singleTrack row after group")
        }
        XCTAssertEqual(parentGroup, .video)
        // Row 2: effectsLane (always last).
        XCTAssertEqual(rows[2].kind, .effectsLane)
    }

    func test_computeDisplayRows_allMembersBrokenOut_skipsGroupRowEntirely() {
        // Two video tracks both broken out — no group row at all,
        // just two singleTrack rows + effects.
        var project = makeTwoTrackProject()
        project.timelineLaneCollapse = [.video: true]
        for idx in project.tracks.indices where project.tracks[idx].kind.laneGroup == .video {
            project.tracks[idx].laneBreakout = true
        }
        let rows = TimelineLayoutCalculator.computeDisplayRows(project: project)
        for row in rows.prefix(2) {
            if case .groupedVideo = row.kind {
                XCTFail("no group row should be emitted when all members are broken out")
            }
        }
        XCTAssertEqual(rows.last?.kind, .effectsLane)
    }

    func test_moveEffectKeyframePreview_clampsAtTimelineStart() {
        let project = makeProjectWithKeyframe(start: 2, duration: 1)
        let kfID = project.effects[0].id
        let layout = TimelineLayoutCalculator.layout(
            project: project,
            viewport: TimelineViewport(size: CGSize(width: 1000, height: 240), pixelsPerSecond: 100),
            dragPreview: .moveEffectKeyframe(kfID, deltaPixels: -500)
        )
        XCTAssertEqual(
            layout.effectsLane.keyframes[0].frame.origin.x,
            TimelineLayoutCalculator.trackHeaderWidth,
            accuracy: 0.001
        )
    }

    private func makeProjectWithKeyframe(start: Double, duration: Double) -> Project {
        var project = makeSingleClipProject(durationSeconds: max(start + duration + 1, 5))
        let kf = EffectKeyframe(
            kind: .zoom,
            timelineRange: TimeRange(start: rt(start), duration: rt(duration))
        )
        project.effects = [kf]
        return project
    }

    // MARK: - Helpers

    private func makeSingleClipProject(durationSeconds: Double, startSeconds: Double = 0) -> Project {
        let asset = MediaAsset(
            kind: .display,
            relativePath: "media/screen.mov",
            captureStart: nil,
            nativeDuration: rt(durationSeconds)
        )
        let clip = Clip(
            assetID: asset.id,
            sourceRange: TimeRange(start: rt(0), duration: rt(durationSeconds)),
            timelineRange: TimeRange(start: rt(startSeconds), duration: rt(durationSeconds))
        )
        let track = Track(kind: .screen, name: "Screen", clips: [clip])
        var project = Project(name: "Single")
        project.assets = [asset]
        project.tracks = [track]
        return project
    }

    private func makeTwoTrackProject() -> Project {
        let asset = MediaAsset(
            kind: .display,
            relativePath: "media/screen.mov",
            captureStart: nil,
            nativeDuration: rt(10)
        )
        let asset2 = MediaAsset(
            kind: .webcam,
            relativePath: "media/cam.mov",
            captureStart: nil,
            nativeDuration: rt(10)
        )
        let clip1 = Clip(
            assetID: asset.id,
            sourceRange: TimeRange(start: rt(0), duration: rt(5)),
            timelineRange: TimeRange(start: rt(0), duration: rt(5))
        )
        let clip2 = Clip(
            assetID: asset2.id,
            sourceRange: TimeRange(start: rt(0), duration: rt(4)),
            timelineRange: TimeRange(start: rt(2), duration: rt(4))
        )
        let track1 = Track(kind: .screen, name: "Screen", clips: [clip1])
        let track2 = Track(kind: .webcam, name: "Webcam", clips: [clip2])
        var project = Project(name: "Two")
        project.assets = [asset, asset2]
        project.tracks = [track1, track2]
        return project
    }

    // MARK: - Branch B — computeDisplayRows (Slice B.2)

    func test_computeDisplayRows_emptyProject_returnsOnlyEffectsLane() {
        let project = Project(name: "Empty")
        let rows = TimelineLayoutCalculator.computeDisplayRows(project: project)
        XCTAssertEqual(rows.count, 1)
        guard case .effectsLane = rows.first?.kind else {
            return XCTFail("expected single effectsLane row, got \(String(describing: rows.first?.kind))")
        }
    }

    func test_computeDisplayRows_smartDefault_collapsedForFreshProject() {
        // Fresh project with screen + cam + mic: smart-default seed is
        // true, so both groups present and both collapsed.
        let project = makeFourTrackProject()
        let rows = TimelineLayoutCalculator.computeDisplayRows(project: project)
        XCTAssertEqual(rows.count, 3,
                       "expected 1 video grouped row + 1 audio grouped row + 1 effects row")
        XCTAssertTrue(rows[0].isCollapsed)
        XCTAssertTrue(rows[1].isCollapsed)
        guard case .groupedVideo = rows[0].kind else {
            return XCTFail("first row should be groupedVideo")
        }
        guard case .groupedAudio = rows[1].kind else {
            return XCTFail("second row should be groupedAudio")
        }
        guard case .effectsLane = rows[2].kind else {
            return XCTFail("third row should be effectsLane")
        }
    }

    func test_computeDisplayRows_collapsed_groupsVideoAndAudio() {
        var project = makeFourTrackProject()
        project.timelineLaneCollapse = [.video: true, .audio: true]
        let rows = TimelineLayoutCalculator.computeDisplayRows(project: project)
        XCTAssertEqual(rows.count, 3)
        guard case .groupedVideo(let videoTracks, let primaryVideo) = rows[0].kind else {
            return XCTFail("expected groupedVideo row")
        }
        XCTAssertEqual(videoTracks.count, 2, "screen + webcam → grouped video")
        // Primary is the screen track (we built the project with it as
        // tracks[0]).
        XCTAssertEqual(primaryVideo, project.tracks[0].id)
        guard case .groupedAudio(let audioTracks, let primaryAudio) = rows[1].kind else {
            return XCTFail("expected groupedAudio row")
        }
        XCTAssertEqual(audioTracks.count, 2, "mic + sysAudio → grouped audio")
        XCTAssertEqual(primaryAudio, project.tracks[2].id, "mic is primary")
    }

    func test_computeDisplayRows_expanded_returnsPerPhysicalTrack() {
        var project = makeFourTrackProject()
        project.timelineLaneCollapse = [.video: false, .audio: false]
        let rows = TimelineLayoutCalculator.computeDisplayRows(project: project)
        XCTAssertEqual(rows.count, 5, "4 single-track rows + effects")
        // First two rows are video children (in physical track order).
        for index in 0...1 {
            guard case .singleTrack(let trackID, let parent) = rows[index].kind else {
                return XCTFail("row \(index) should be singleTrack")
            }
            XCTAssertEqual(trackID, project.tracks[index].id)
            XCTAssertEqual(parent, .video)
            XCTAssertFalse(rows[index].isCollapsed)
        }
        // Next two are audio children.
        for index in 2...3 {
            guard case .singleTrack(_, let parent) = rows[index].kind else {
                return XCTFail("row \(index) should be singleTrack")
            }
            XCTAssertEqual(parent, .audio)
        }
        guard case .effectsLane = rows[4].kind else {
            return XCTFail("last row should be effectsLane")
        }
    }

    func test_computeDisplayRows_mixedCollapsed_videoCollapsedAudioExpanded() {
        var project = makeFourTrackProject()
        project.timelineLaneCollapse = [.video: true, .audio: false]
        let rows = TimelineLayoutCalculator.computeDisplayRows(project: project)
        // Expect: groupedVideo (1 row), singleTrack(mic), singleTrack(sysAudio), effectsLane
        XCTAssertEqual(rows.count, 4)
        guard case .groupedVideo = rows[0].kind else {
            return XCTFail("expected groupedVideo row first")
        }
        XCTAssertTrue(rows[0].isCollapsed)
        guard case .singleTrack(_, .audio) = rows[1].kind,
              case .singleTrack(_, .audio) = rows[2].kind else {
            return XCTFail("expected audio singleTrack rows after video group")
        }
    }

    func test_computeDisplayRows_videoOnlyProject_hasNoAudioGroup() {
        // Project with screen only — no audio tracks at all. Should
        // emit just the video group + effects, no audio row.
        let project = makeSingleClipProject(durationSeconds: 3)
        let rows = TimelineLayoutCalculator.computeDisplayRows(project: project)
        XCTAssertEqual(rows.count, 2, "video group + effects only")
        guard case .groupedVideo = rows[0].kind else {
            return XCTFail("first row should be groupedVideo")
        }
        guard case .effectsLane = rows[1].kind else {
            return XCTFail("second row should be effectsLane")
        }
    }

    func test_computeDisplayRows_primaryFallsBackWhenNoScreenTrack() {
        // Video group with only a webcam track — primary should be the
        // webcam track itself (fallback path).
        let asset = MediaAsset(
            kind: .webcam,
            relativePath: "media/cam.mov",
            captureStart: nil,
            nativeDuration: rt(3)
        )
        let clip = Clip(
            assetID: asset.id,
            sourceRange: TimeRange(start: rt(0), duration: rt(3)),
            timelineRange: TimeRange(start: rt(0), duration: rt(3))
        )
        let camTrack = Track(kind: .webcam, name: "Webcam", clips: [clip])
        var project = Project(name: "WebcamOnly")
        project.assets = [asset]
        project.tracks = [camTrack]
        let rows = TimelineLayoutCalculator.computeDisplayRows(project: project)
        guard case .groupedVideo(let ids, let primary) = rows[0].kind else {
            return XCTFail("expected groupedVideo with webcam-only fallback")
        }
        XCTAssertEqual(ids, [camTrack.id])
        XCTAssertEqual(primary, camTrack.id, "primary falls back to first track when no .screen kind present")
    }

    // MARK: - Branch B — grouped-lane overlap badges (Slice B.3)

    func test_groupedVideoBadge_appears_whenWebcamClipOverlapsScreenClip() {
        // Fresh four-track project (collapsed by default). Screen clip
        // and webcam clip both span 0..5s → they overlap → expect one
        // video badge on the screen clip.
        let project = makeFourTrackProject()
        let layout = TimelineLayoutCalculator.layout(
            project: project,
            viewport: TimelineViewport(size: CGSize(width: 800, height: 240), pixelsPerSecond: 80)
        )
        let videoBadges = layout.groupedOverlapBadges.filter { $0.kind == .video }
        XCTAssertEqual(videoBadges.count, 1, "expected one video badge for overlapping screen+cam clips")
        XCTAssertEqual(videoBadges[0].primaryClipID,
                       project.tracks[0].clips[0].id,
                       "badge should anchor on the screen (primary) clip")
    }

    func test_groupedAudioBadge_appears_whenSystemAudioOverlapsMic() {
        let project = makeFourTrackProject()
        let layout = TimelineLayoutCalculator.layout(
            project: project,
            viewport: TimelineViewport(size: CGSize(width: 800, height: 240), pixelsPerSecond: 80)
        )
        let audioBadges = layout.groupedOverlapBadges.filter { $0.kind == .audio }
        XCTAssertEqual(audioBadges.count, 1, "expected one audio badge for overlapping mic+sysAudio clips")
        XCTAssertEqual(audioBadges[0].primaryClipID,
                       project.tracks[2].clips[0].id,
                       "badge should anchor on the mic (primary) clip")
    }

    func test_groupedOverlapBadges_noneWhenExpanded() {
        var project = makeFourTrackProject()
        project.timelineLaneCollapse = [.video: false, .audio: false]
        let layout = TimelineLayoutCalculator.layout(
            project: project,
            viewport: TimelineViewport(size: CGSize(width: 800, height: 240), pixelsPerSecond: 80)
        )
        XCTAssertTrue(layout.groupedOverlapBadges.isEmpty,
                      "expanded rows render the secondary track directly — no badge needed")
    }

    func test_groupedOverlapBadges_oneBadgePerPrimaryClip() {
        // Webcam clip overlaps the screen clip's window AND a screen
        // clip exists at a different range. Confirm one badge per
        // primary clip, not one per secondary overlap.
        let screenAsset = MediaAsset(kind: .display, relativePath: "media/s.mov",
                                     captureStart: nil, nativeDuration: rt(10))
        let camAsset = MediaAsset(kind: .webcam, relativePath: "media/c.mov",
                                  captureStart: nil, nativeDuration: rt(10))
        let screenClip1 = Clip(
            assetID: screenAsset.id,
            sourceRange: TimeRange(start: rt(0), duration: rt(4)),
            timelineRange: TimeRange(start: rt(0), duration: rt(4))
        )
        let screenClip2 = Clip(
            assetID: screenAsset.id,
            sourceRange: TimeRange(start: rt(0), duration: rt(4)),
            timelineRange: TimeRange(start: rt(6), duration: rt(4))
        )
        // Two webcam clips: one overlaps screenClip1, one overlaps screenClip2.
        let camClip1 = Clip(
            assetID: camAsset.id,
            sourceRange: TimeRange(start: rt(0), duration: rt(2)),
            timelineRange: TimeRange(start: rt(1), duration: rt(2))
        )
        let camClip2 = Clip(
            assetID: camAsset.id,
            sourceRange: TimeRange(start: rt(0), duration: rt(2)),
            timelineRange: TimeRange(start: rt(7), duration: rt(2))
        )
        let screenTrack = Track(kind: .screen, name: "Screen", clips: [screenClip1, screenClip2])
        let camTrack = Track(kind: .webcam, name: "Webcam", clips: [camClip1, camClip2])
        var project = Project(name: "Multi")
        project.assets = [screenAsset, camAsset]
        project.tracks = [screenTrack, camTrack]
        let layout = TimelineLayoutCalculator.layout(
            project: project,
            viewport: TimelineViewport(size: CGSize(width: 1600, height: 240), pixelsPerSecond: 100)
        )
        XCTAssertEqual(layout.groupedOverlapBadges.count, 2,
                       "expect one badge per primary clip with secondary overlap")
        let badgedIDs = Set(layout.groupedOverlapBadges.map(\.primaryClipID))
        XCTAssertTrue(badgedIDs.contains(screenClip1.id))
        XCTAssertTrue(badgedIDs.contains(screenClip2.id))
    }

    // MARK: - Branch B — disclosure triangle hit-test (Slice B.4)

    func test_laneDisclosure_emittedPerGroup_collapsed() {
        let project = makeFourTrackProject()
        let layout = TimelineLayoutCalculator.layout(
            project: project,
            viewport: TimelineViewport(size: CGSize(width: 800, height: 240), pixelsPerSecond: 80)
        )
        XCTAssertEqual(layout.laneDisclosures.count, 2, "video + audio groups")
        XCTAssertTrue(layout.laneDisclosures.allSatisfy { $0.isCollapsed },
                      "smart-default seed = collapsed → both chevrons render as right-pointing")
    }

    func test_laneDisclosure_oneChevronOnFirstChild_whenExpanded() {
        var project = makeFourTrackProject()
        project.timelineLaneCollapse = [.video: false]
        let layout = TimelineLayoutCalculator.layout(
            project: project,
            viewport: TimelineViewport(size: CGSize(width: 800, height: 240), pixelsPerSecond: 80)
        )
        let videoDisclosure = layout.laneDisclosures.first(where: { $0.groupID == .video })
        XCTAssertNotNil(videoDisclosure)
        XCTAssertFalse(videoDisclosure?.isCollapsed ?? true,
                       "expanded video group's chevron points down")
    }

    func test_hitTest_onLaneDisclosure_returnsDisclosureCase() {
        let project = makeFourTrackProject()
        let layout = TimelineLayoutCalculator.layout(
            project: project,
            viewport: TimelineViewport(size: CGSize(width: 800, height: 240), pixelsPerSecond: 80)
        )
        guard let videoChevron = layout.laneDisclosures.first(where: { $0.groupID == .video }) else {
            return XCTFail("expected a video chevron in the layout")
        }
        let hit = TimelineHitTest.hit(
            at: CGPoint(x: videoChevron.hitFrame.midX, y: videoChevron.hitFrame.midY),
            in: layout
        )
        XCTAssertEqual(hit, .laneDisclosure(.video))
    }

    func test_layout_returnsDisplayRows_alongsideTracks() {
        // Sanity-check that `layout()` now plumbs computeDisplayRows
        // through into the TimelineLayout struct.
        let project = makeFourTrackProject()
        let layout = TimelineLayoutCalculator.layout(
            project: project,
            viewport: TimelineViewport(size: CGSize(width: 800, height: 240), pixelsPerSecond: 80)
        )
        XCTAssertEqual(layout.tracks.count, 4, "physical tracks still emitted in full for legacy code paths")
        XCTAssertEqual(layout.displayRows.count, 3, "grouped rows: video + audio + effects (smart default = collapsed)")
    }

    /// Four-track project (screen + cam + mic + sysAudio) covering all
    /// four common Phase 5 scenes-mode track kinds. Each track gets one
    /// short clip so layout / hit-test still pass.
    private func makeFourTrackProject() -> Project {
        let screenAsset = MediaAsset(kind: .display, relativePath: "media/screen.mov",
                                     captureStart: nil, nativeDuration: rt(5))
        let camAsset = MediaAsset(kind: .webcam, relativePath: "media/cam.mov",
                                  captureStart: nil, nativeDuration: rt(5))
        let micAsset = MediaAsset(kind: .microphone, relativePath: "media/mic.m4a",
                                  captureStart: nil, nativeDuration: rt(5))
        let sysAsset = MediaAsset(kind: .systemAudio, relativePath: "media/sys.m4a",
                                  captureStart: nil, nativeDuration: rt(5))
        let mkClip: (MediaAsset) -> Clip = { [self] asset in
            Clip(
                assetID: asset.id,
                sourceRange: TimeRange(start: rt(0), duration: rt(5)),
                timelineRange: TimeRange(start: rt(0), duration: rt(5))
            )
        }
        let screenTrack = Track(kind: .screen, name: "Screen", clips: [mkClip(screenAsset)])
        let camTrack = Track(kind: .webcam, name: "Webcam", clips: [mkClip(camAsset)])
        let micTrack = Track(kind: .microphone, name: "Mic", clips: [mkClip(micAsset)])
        let sysTrack = Track(kind: .systemAudio, name: "System Audio", clips: [mkClip(sysAsset)])
        var project = Project(name: "Four")
        project.assets = [screenAsset, camAsset, micAsset, sysAsset]
        project.tracks = [screenTrack, camTrack, micTrack, sysTrack]
        return project
    }

    private func rt(_ seconds: Double) -> RationalTime {
        RationalTime.seconds(seconds)
    }
}
