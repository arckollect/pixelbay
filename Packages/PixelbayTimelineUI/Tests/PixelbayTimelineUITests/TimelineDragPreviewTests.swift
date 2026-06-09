import CoreGraphics
import PixelbayCore
@testable import PixelbayTimelineUI
import XCTest

/// Pin the layout-calculator's drag-preview math. The NSView feeds a
/// pixel-space delta in during mouseDragged; the layout calculator
/// applies it to the matching clip's frame so the user sees a live
/// preview before mouseUp commits the actual EditCommand.
final class TimelineDragPreviewTests: XCTestCase {
    private func makeSingleClipProject(durationSeconds: Double, startSeconds: Double = 1) -> Project {
        let asset = MediaAsset(
            kind: .display,
            relativePath: "media/screen.mov",
            captureStart: nil,
            nativeDuration: RationalTime.seconds(durationSeconds + startSeconds)
        )
        let clip = Clip(
            assetID: asset.id,
            sourceRange: TimeRange(start: RationalTime.seconds(0), duration: RationalTime.seconds(durationSeconds)),
            timelineRange: TimeRange(
                start: RationalTime.seconds(startSeconds),
                duration: RationalTime.seconds(durationSeconds)
            )
        )
        let track = Track(kind: .screen, name: "Screen", clips: [clip])
        var project = Project(name: "Drag")
        project.assets = [asset]
        project.tracks = [track]
        return project
    }

    func test_movePreview_shiftsClipFrameRight() {
        let project = makeSingleClipProject(durationSeconds: 4, startSeconds: 1)
        let clipID = project.tracks[0].clips[0].id
        let viewport = TimelineViewport(size: CGSize(width: 1000, height: 240), pixelsPerSecond: 100)

        let baseline = TimelineLayoutCalculator.layout(project: project, viewport: viewport)
        let baselineX = baseline.tracks[0].clips[0].frame.origin.x

        let dragged = TimelineLayoutCalculator.layout(
            project: project,
            viewport: viewport,
            dragPreview: .moveClip(clipID, deltaPixels: 50)
        )
        XCTAssertEqual(dragged.tracks[0].clips[0].frame.origin.x, baselineX + 50, accuracy: 0.001)
        XCTAssertEqual(dragged.tracks[0].clips[0].frame.size.width,
                       baseline.tracks[0].clips[0].frame.size.width,
                       accuracy: 0.001,
                       "Move shouldn't change width")
    }

    func test_movePreview_negativeDelta_shiftsLeft() {
        let project = makeSingleClipProject(durationSeconds: 4, startSeconds: 2)
        let clipID = project.tracks[0].clips[0].id
        let viewport = TimelineViewport(size: CGSize(width: 1000, height: 240), pixelsPerSecond: 100)
        let baseline = TimelineLayoutCalculator.layout(project: project, viewport: viewport)
        let dragged = TimelineLayoutCalculator.layout(
            project: project,
            viewport: viewport,
            dragPreview: .moveClip(clipID, deltaPixels: -75)
        )
        XCTAssertEqual(dragged.tracks[0].clips[0].frame.origin.x,
                       baseline.tracks[0].clips[0].frame.origin.x - 75,
                       accuracy: 0.001)
    }

    func test_trimInPreview_movesXAndShrinksWidth() {
        let project = makeSingleClipProject(durationSeconds: 4, startSeconds: 1)
        let clipID = project.tracks[0].clips[0].id
        let viewport = TimelineViewport(size: CGSize(width: 1000, height: 240), pixelsPerSecond: 100)
        let baseline = TimelineLayoutCalculator.layout(project: project, viewport: viewport)
        let baselineFrame = baseline.tracks[0].clips[0].frame

        let dragged = TimelineLayoutCalculator.layout(
            project: project,
            viewport: viewport,
            dragPreview: .trimIn(clipID, deltaPixels: 80)
        )
        let post = dragged.tracks[0].clips[0].frame
        XCTAssertEqual(post.origin.x, baselineFrame.origin.x + 80, accuracy: 0.001)
        XCTAssertEqual(post.size.width, baselineFrame.size.width - 80, accuracy: 0.001)
    }

    func test_trimInPreview_clampsToOnePixelWidth_atExtreme() {
        let project = makeSingleClipProject(durationSeconds: 4, startSeconds: 1)
        let clipID = project.tracks[0].clips[0].id
        let viewport = TimelineViewport(size: CGSize(width: 1000, height: 240), pixelsPerSecond: 100)
        let dragged = TimelineLayoutCalculator.layout(
            project: project,
            viewport: viewport,
            dragPreview: .trimIn(clipID, deltaPixels: 99999)
        )
        XCTAssertGreaterThanOrEqual(dragged.tracks[0].clips[0].frame.size.width, 1)
    }

    func test_trimOutPreview_extendsWidth() {
        let project = makeSingleClipProject(durationSeconds: 4, startSeconds: 1)
        let clipID = project.tracks[0].clips[0].id
        let viewport = TimelineViewport(size: CGSize(width: 1000, height: 240), pixelsPerSecond: 100)
        let baseline = TimelineLayoutCalculator.layout(project: project, viewport: viewport)
        let baselineFrame = baseline.tracks[0].clips[0].frame
        let dragged = TimelineLayoutCalculator.layout(
            project: project,
            viewport: viewport,
            dragPreview: .trimOut(clipID, deltaPixels: 60)
        )
        let post = dragged.tracks[0].clips[0].frame
        XCTAssertEqual(post.origin.x, baselineFrame.origin.x, accuracy: 0.001, "Trim-out shouldn't move x")
        XCTAssertEqual(post.size.width, baselineFrame.size.width + 60, accuracy: 0.001)
    }

    func test_trimOutPreview_clampsToOnePixelWidth_atExtreme() {
        let project = makeSingleClipProject(durationSeconds: 4, startSeconds: 1)
        let clipID = project.tracks[0].clips[0].id
        let viewport = TimelineViewport(size: CGSize(width: 1000, height: 240), pixelsPerSecond: 100)
        let dragged = TimelineLayoutCalculator.layout(
            project: project,
            viewport: viewport,
            dragPreview: .trimOut(clipID, deltaPixels: -99999)
        )
        XCTAssertGreaterThanOrEqual(dragged.tracks[0].clips[0].frame.size.width, 1)
    }

    func test_dragPreview_doesNotAffectOtherClips() {
        let project = makeTwoClipProject()
        let clipAID = project.tracks[0].clips[0].id
        let clipBID = project.tracks[0].clips[1].id
        let viewport = TimelineViewport(size: CGSize(width: 1000, height: 240), pixelsPerSecond: 100)
        let baseline = TimelineLayoutCalculator.layout(project: project, viewport: viewport)
        let dragged = TimelineLayoutCalculator.layout(
            project: project,
            viewport: viewport,
            dragPreview: .moveClip(clipAID, deltaPixels: 50)
        )
        // B's frame should be unchanged when only A is being dragged.
        let baselineB = baseline.tracks[0].clips.first(where: { $0.id == clipBID })!.frame
        let draggedB = dragged.tracks[0].clips.first(where: { $0.id == clipBID })!.frame
        XCTAssertEqual(baselineB, draggedB)
    }

    // MARK: - Effect keyframe drag preview

    func test_moveEffectKeyframe_shiftsFrameRight() {
        let project = makeProjectWithKeyframe(start: 1, duration: 2)
        let kfID = project.effects[0].id
        let viewport = TimelineViewport(size: CGSize(width: 1000, height: 240), pixelsPerSecond: 100)
        let baseline = TimelineLayoutCalculator.layout(project: project, viewport: viewport)
        let baselineX = baseline.effectsLane.keyframes[0].frame.origin.x
        let baselineW = baseline.effectsLane.keyframes[0].frame.size.width

        let dragged = TimelineLayoutCalculator.layout(
            project: project,
            viewport: viewport,
            dragPreview: .moveEffectKeyframe(kfID, deltaPixels: 60)
        )
        let post = dragged.effectsLane.keyframes[0].frame
        XCTAssertEqual(post.origin.x, baselineX + 60, accuracy: 0.001)
        XCTAssertEqual(post.size.width, baselineW, accuracy: 0.001, "Move shouldn't change width")
    }

    func test_trimEffectKeyframeIn_shiftsXAndShrinksWidth() {
        let project = makeProjectWithKeyframe(start: 1, duration: 3)
        let kfID = project.effects[0].id
        let viewport = TimelineViewport(size: CGSize(width: 1000, height: 240), pixelsPerSecond: 100)
        let baseline = TimelineLayoutCalculator.layout(project: project, viewport: viewport)
        let baselineFrame = baseline.effectsLane.keyframes[0].frame
        let dragged = TimelineLayoutCalculator.layout(
            project: project,
            viewport: viewport,
            dragPreview: .trimEffectKeyframeIn(kfID, deltaPixels: 80)
        )
        let post = dragged.effectsLane.keyframes[0].frame
        XCTAssertEqual(post.origin.x, baselineFrame.origin.x + 80, accuracy: 0.001)
        XCTAssertEqual(post.size.width, baselineFrame.size.width - 80, accuracy: 0.001)
    }

    func test_trimEffectKeyframeIn_clampsToMinWidth() {
        let project = makeProjectWithKeyframe(start: 1, duration: 2)
        let kfID = project.effects[0].id
        let viewport = TimelineViewport(size: CGSize(width: 1000, height: 240), pixelsPerSecond: 100)
        let dragged = TimelineLayoutCalculator.layout(
            project: project,
            viewport: viewport,
            dragPreview: .trimEffectKeyframeIn(kfID, deltaPixels: 99999)
        )
        XCTAssertGreaterThanOrEqual(dragged.effectsLane.keyframes[0].frame.size.width, 1)
    }

    func test_trimEffectKeyframeIn_clampsAtTimelineStart_preservingRightEdge() {
        let project = makeProjectWithKeyframe(start: 1, duration: 3)
        let kfID = project.effects[0].id
        let viewport = TimelineViewport(size: CGSize(width: 1000, height: 240), pixelsPerSecond: 100)
        let baseline = TimelineLayoutCalculator.layout(project: project, viewport: viewport)
        let baselineFrame = baseline.effectsLane.keyframes[0].frame

        let dragged = TimelineLayoutCalculator.layout(
            project: project,
            viewport: viewport,
            dragPreview: .trimEffectKeyframeIn(kfID, deltaPixels: -500)
        )
        let post = dragged.effectsLane.keyframes[0].frame
        XCTAssertEqual(post.origin.x, TimelineLayoutCalculator.trackHeaderWidth, accuracy: 0.001)
        XCTAssertEqual(post.maxX, baselineFrame.maxX, accuracy: 0.001)
    }

    func test_trimEffectKeyframeOut_extendsWidth() {
        let project = makeProjectWithKeyframe(start: 1, duration: 2)
        let kfID = project.effects[0].id
        let viewport = TimelineViewport(size: CGSize(width: 1000, height: 240), pixelsPerSecond: 100)
        let baseline = TimelineLayoutCalculator.layout(project: project, viewport: viewport)
        let baselineFrame = baseline.effectsLane.keyframes[0].frame
        let dragged = TimelineLayoutCalculator.layout(
            project: project,
            viewport: viewport,
            dragPreview: .trimEffectKeyframeOut(kfID, deltaPixels: 50)
        )
        let post = dragged.effectsLane.keyframes[0].frame
        XCTAssertEqual(post.origin.x, baselineFrame.origin.x, accuracy: 0.001)
        XCTAssertEqual(post.size.width, baselineFrame.size.width + 50, accuracy: 0.001)
    }

    func test_trimEffectKeyframeOut_clampsToMinWidth() {
        let project = makeProjectWithKeyframe(start: 1, duration: 2)
        let kfID = project.effects[0].id
        let viewport = TimelineViewport(size: CGSize(width: 1000, height: 240), pixelsPerSecond: 100)
        let dragged = TimelineLayoutCalculator.layout(
            project: project,
            viewport: viewport,
            dragPreview: .trimEffectKeyframeOut(kfID, deltaPixels: -99999)
        )
        XCTAssertGreaterThanOrEqual(dragged.effectsLane.keyframes[0].frame.size.width, 1)
    }

    func test_effectDragPreview_doesNotAffectOtherKeyframes() {
        var project = makeSingleClipProject(durationSeconds: 10, startSeconds: 0)
        let kfA = EffectKeyframe(kind: .zoom,
                                 timelineRange: TimeRange(start: RationalTime.seconds(1), duration: RationalTime.seconds(2)))
        let kfB = EffectKeyframe(kind: .talkingHeadSwap,
                                 timelineRange: TimeRange(start: RationalTime.seconds(5), duration: RationalTime.seconds(2)))
        project.effects = [kfA, kfB]
        let viewport = TimelineViewport(size: CGSize(width: 1200, height: 240), pixelsPerSecond: 100)
        let baseline = TimelineLayoutCalculator.layout(project: project, viewport: viewport)
        let dragged = TimelineLayoutCalculator.layout(
            project: project,
            viewport: viewport,
            dragPreview: .moveEffectKeyframe(kfA.id, deltaPixels: 50)
        )
        let baselineB = baseline.effectsLane.keyframes.first(where: { $0.id == kfB.id })!.frame
        let draggedB = dragged.effectsLane.keyframes.first(where: { $0.id == kfB.id })!.frame
        XCTAssertEqual(baselineB, draggedB)
    }

    func test_effectDragPreview_doesNotAffectClipFrames() {
        let project = makeProjectWithKeyframe(start: 1, duration: 2)
        let kfID = project.effects[0].id
        let viewport = TimelineViewport(size: CGSize(width: 1000, height: 240), pixelsPerSecond: 100)
        let baseline = TimelineLayoutCalculator.layout(project: project, viewport: viewport)
        let baselineClip = baseline.tracks[0].clips[0].frame
        let dragged = TimelineLayoutCalculator.layout(
            project: project,
            viewport: viewport,
            dragPreview: .moveEffectKeyframe(kfID, deltaPixels: 50)
        )
        XCTAssertEqual(dragged.tracks[0].clips[0].frame, baselineClip)
    }

    private func makeProjectWithKeyframe(start: Double, duration: Double) -> Project {
        var project = makeSingleClipProject(durationSeconds: max(start + duration + 1, 5), startSeconds: 0)
        let kf = EffectKeyframe(
            kind: .zoom,
            timelineRange: TimeRange(
                start: RationalTime.seconds(start),
                duration: RationalTime.seconds(duration)
            )
        )
        project.effects = [kf]
        return project
    }

    private func makeTwoClipProject() -> Project {
        let asset = MediaAsset(
            kind: .display,
            relativePath: "media/screen.mov",
            captureStart: nil,
            nativeDuration: RationalTime.seconds(10)
        )
        let clipA = Clip(
            assetID: asset.id,
            sourceRange: TimeRange(start: RationalTime.seconds(0), duration: RationalTime.seconds(2)),
            timelineRange: TimeRange(start: RationalTime.seconds(0), duration: RationalTime.seconds(2))
        )
        let clipB = Clip(
            assetID: asset.id,
            sourceRange: TimeRange(start: RationalTime.seconds(2), duration: RationalTime.seconds(2)),
            timelineRange: TimeRange(start: RationalTime.seconds(3), duration: RationalTime.seconds(2))
        )
        let track = Track(kind: .screen, name: "Screen", clips: [clipA, clipB])
        var project = Project(name: "Two")
        project.assets = [asset]
        project.tracks = [track]
        return project
    }
}
