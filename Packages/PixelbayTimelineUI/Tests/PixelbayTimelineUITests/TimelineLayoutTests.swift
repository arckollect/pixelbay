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
        let project = makeTwoTrackProject()
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

    func test_totalContentHeight_grows_withTrackCount() {
        let single = TimelineLayoutCalculator.layout(
            project: makeSingleClipProject(durationSeconds: 1),
            viewport: TimelineViewport(size: CGSize(width: 400, height: 240), pixelsPerSecond: 80)
        )
        let two = TimelineLayoutCalculator.layout(
            project: makeTwoTrackProject(),
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

    private func rt(_ seconds: Double) -> RationalTime {
        RationalTime.seconds(seconds)
    }
}
