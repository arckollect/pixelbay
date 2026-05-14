import CoreGraphics
import Foundation
import PixelbayCore

// Pure-data layout calculator for the timeline track view. Takes a Project
// + viewport state (size, zoom, scroll) and emits per-track / per-clip
// frames in the timeline view's local coordinate space (top-left origin,
// y growing downward — matches NSView's flipped coordinate system).
//
// Lives outside the AppKit code so the math is unit-testable without
// instantiating an NSView.
//
// Coordinate conventions:
//   • x = trackHeaderWidth + (clipTimelineSeconds - scrollX) * pixelsPerSecond
//   • y = trackIndex * (trackHeight + trackSpacing) + verticalInset
//   • A clip with x + width <= trackHeaderWidth or x >= viewport.width is
//     omitted from the layout (off-screen, no need to render).

public struct TimelineLayout: Sendable, Equatable {
    public var totalContentWidth: CGFloat   // total width including off-screen clips
    public var totalContentHeight: CGFloat
    public var tracks: [TrackLayout]
    /// Read-only effects row rendered below `tracks`. Always present, even
    /// when `project.effects` is empty — header + lane chrome still draw so
    /// the user knows the slot exists. Per Phase 3b backlog #3.
    public var effectsLane: EffectsLaneLayout
    public var rulerHeight: CGFloat
    public var trackHeaderWidth: CGFloat

    public init(
        totalContentWidth: CGFloat,
        totalContentHeight: CGFloat,
        tracks: [TrackLayout],
        effectsLane: EffectsLaneLayout,
        rulerHeight: CGFloat,
        trackHeaderWidth: CGFloat
    ) {
        self.totalContentWidth = totalContentWidth
        self.totalContentHeight = totalContentHeight
        self.tracks = tracks
        self.effectsLane = effectsLane
        self.rulerHeight = rulerHeight
        self.trackHeaderWidth = trackHeaderWidth
    }
}

public struct EffectsLaneLayout: Sendable, Equatable {
    public var headerFrame: CGRect
    public var laneFrame: CGRect
    public var keyframes: [EffectKeyframeLayout]

    public init(headerFrame: CGRect, laneFrame: CGRect, keyframes: [EffectKeyframeLayout]) {
        self.headerFrame = headerFrame
        self.laneFrame = laneFrame
        self.keyframes = keyframes
    }
}

public struct EffectKeyframeLayout: Sendable, Equatable, Identifiable {
    public let id: EffectKeyframeID
    public let kind: EffectKind
    public let origin: ZoomOrigin
    public var frame: CGRect

    public init(id: EffectKeyframeID, kind: EffectKind, origin: ZoomOrigin = .auto, frame: CGRect) {
        self.id = id
        self.kind = kind
        self.origin = origin
        self.frame = frame
    }
}

public struct TrackLayout: Sendable, Equatable, Identifiable {
    public let id: TrackID
    public let kind: TrackKind
    public let name: String
    /// Header cell in viewport coordinates (left column).
    public var headerFrame: CGRect
    /// Track lane in viewport coordinates (right of header, full timeline width).
    public var laneFrame: CGRect
    public var clips: [ClipLayout]

    public init(
        id: TrackID,
        kind: TrackKind,
        name: String,
        headerFrame: CGRect,
        laneFrame: CGRect,
        clips: [ClipLayout]
    ) {
        self.id = id
        self.kind = kind
        self.name = name
        self.headerFrame = headerFrame
        self.laneFrame = laneFrame
        self.clips = clips
    }
}

public struct ClipLayout: Sendable, Equatable, Identifiable {
    public let id: ClipID
    /// Clip rectangle in viewport coordinates. `x` is relative to the lane's
    /// origin so the renderer can either translate or use absolute coords.
    public var frame: CGRect

    public init(id: ClipID, frame: CGRect) {
        self.id = id
        self.frame = frame
    }
}

public struct TimelineViewport: Sendable, Equatable {
    public var size: CGSize
    /// How many pixels each second of timeline time consumes. Phase 2 ships
    /// 80pt/s as the default; the zoom slider scales between 16 (zoomed-out)
    /// and 800 (per-frame zoom).
    public var pixelsPerSecond: CGFloat
    /// Horizontal scroll offset in seconds (timeline domain). 0 = playhead 0
    /// is at the left edge of the lanes (just past the track headers).
    public var scrollX: CGFloat
    /// Per-track lane height in points. The user-controllable timeline
    /// "row size" — `TimelineLayoutCalculator` uses this when laying out
    /// each track's header / lane / clip rectangles.
    public var trackHeight: CGFloat

    public init(
        size: CGSize,
        pixelsPerSecond: CGFloat,
        scrollX: CGFloat = 0,
        trackHeight: CGFloat = TimelineLayoutCalculator.defaultTrackHeight
    ) {
        self.size = size
        self.pixelsPerSecond = pixelsPerSecond
        self.scrollX = scrollX
        self.trackHeight = trackHeight
    }
}

/// Visual-only representation of an in-progress mouse drag on the timeline.
/// `none` is the steady state. The other cases describe a drag whose
/// commit has not yet happened — the layout calculator applies the pixel-
/// space delta to the affected clip's frame so the user sees a live
/// preview while dragging. The actual `EditCommand` only fires on
/// mouseUp, where pixel delta becomes a `RationalTime` delta and
/// `TrimClipIn / TrimClipOut / MoveClipCommand` is dispatched. This
/// gives us drag-coalescing for free — one command per drag, not one
/// per tick (HANDOFF §3.18 known gap).
public enum TimelineDragPreview: Sendable, Equatable {
    case none
    case moveClip(ClipID, deltaPixels: CGFloat)
    case trimIn(ClipID, deltaPixels: CGFloat)
    case trimOut(ClipID, deltaPixels: CGFloat)
    case moveEffectKeyframe(EffectKeyframeID, deltaPixels: CGFloat)
    case trimEffectKeyframeIn(EffectKeyframeID, deltaPixels: CGFloat)
    case trimEffectKeyframeOut(EffectKeyframeID, deltaPixels: CGFloat)
}

public enum TimelineLayoutCalculator {
    /// Default per-track lane height, used unless the host overrides via
    /// `TimelineViewport.trackHeight`.
    public static let defaultTrackHeight: CGFloat = 56
    /// Compact lower bound — clip names still legible, waveforms reduced
    /// to a single bar.
    public static let minTrackHeight: CGFloat = 24
    /// Roomy upper bound — waveforms fully visible.
    public static let maxTrackHeight: CGFloat = 96
    public static let trackSpacing: CGFloat = 4
    public static let trackHeaderWidth: CGFloat = 140
    public static let rulerHeight: CGFloat = 24
    public static let verticalInset: CGFloat = 8
    public static let defaultPixelsPerSecond: CGFloat = 80
    public static let minPixelsPerSecond: CGFloat = 16
    public static let maxPixelsPerSecond: CGFloat = 800
    /// Effects row sits below all real tracks. Thinner than a regular
    /// track lane because each keyframe is a single rounded badge, not a
    /// scrubbable clip body with a waveform overlay.
    public static let effectsLaneHeight: CGFloat = 28

    public static func layout(
        project: Project,
        viewport: TimelineViewport,
        dragPreview: TimelineDragPreview = .none
    ) -> TimelineLayout {
        let pps = max(minPixelsPerSecond, min(maxPixelsPerSecond, viewport.pixelsPerSecond))
        let trackHeight = max(minTrackHeight, min(maxTrackHeight, viewport.trackHeight))
        let totalSeconds = self.totalSeconds(in: project)
        let totalContentWidth = trackHeaderWidth + max(viewport.size.width - trackHeaderWidth, totalSeconds * pps)
        let totalContentHeight = rulerHeight + verticalInset
            + CGFloat(project.tracks.count) * (trackHeight + trackSpacing)
            + effectsLaneHeight + trackSpacing
            + verticalInset

        var tracks: [TrackLayout] = []
        for (index, track) in project.tracks.enumerated() {
            let yOrigin = rulerHeight + verticalInset
                + CGFloat(index) * (trackHeight + trackSpacing)
            let header = CGRect(x: 0, y: yOrigin, width: trackHeaderWidth, height: trackHeight)
            let laneOriginX = trackHeaderWidth
            let laneWidth = totalContentWidth - trackHeaderWidth
            let lane = CGRect(x: laneOriginX, y: yOrigin, width: laneWidth, height: trackHeight)

            var clipLayouts: [ClipLayout] = []
            for clip in track.clips {
                let clipStartSec = seconds(clip.timelineRange.start)
                let clipDurSec = seconds(clip.timelineRange.duration)
                let xInLane = (clipStartSec - viewport.scrollX) * pps
                var xAbs = laneOriginX + xInLane
                var width = clipDurSec * pps

                switch dragPreview {
                case .none:
                    break
                case .moveClip(let id, let delta) where id == clip.id:
                    xAbs += delta
                case .trimIn(let id, let delta) where id == clip.id:
                    // Drag the in-point: x and width both move; tail
                    // stays put. Don't go to ≤ 0 width or negative
                    // start; the layout shows a clamped preview but
                    // the eventual command (with these same bounds
                    // checks) is what enforces correctness.
                    let clamped = min(delta, width - 1)
                    xAbs += clamped
                    width -= clamped
                case .trimOut(let id, let delta) where id == clip.id:
                    let clamped = max(delta, -(width - 1))
                    width += clamped
                default:
                    break
                }

                clipLayouts.append(ClipLayout(
                    id: clip.id,
                    frame: CGRect(x: xAbs, y: yOrigin, width: width, height: trackHeight)
                ))
            }

            tracks.append(TrackLayout(
                id: track.id,
                kind: track.kind,
                name: track.name,
                headerFrame: header,
                laneFrame: lane,
                clips: clipLayouts
            ))
        }

        let effectsLaneY = rulerHeight + verticalInset
            + CGFloat(project.tracks.count) * (trackHeight + trackSpacing)
        let effectsHeader = CGRect(
            x: 0, y: effectsLaneY,
            width: trackHeaderWidth, height: effectsLaneHeight
        )
        let effectsLaneOriginX = trackHeaderWidth
        let effectsLaneWidth = totalContentWidth - trackHeaderWidth
        let effectsLaneRect = CGRect(
            x: effectsLaneOriginX, y: effectsLaneY,
            width: effectsLaneWidth, height: effectsLaneHeight
        )
        var keyframeLayouts: [EffectKeyframeLayout] = []
        for kf in project.effects {
            let startSec = seconds(kf.timelineRange.start)
            let durSec = seconds(kf.timelineRange.duration)
            let xInLane = (startSec - viewport.scrollX) * pps
            var xAbs = effectsLaneOriginX + xInLane
            var width = durSec * pps

            switch dragPreview {
            case .moveEffectKeyframe(let id, let delta) where id == kf.id:
                xAbs += delta
            case .trimEffectKeyframeIn(let id, let delta) where id == kf.id:
                let clamped = min(delta, width - 1)
                xAbs += clamped
                width -= clamped
            case .trimEffectKeyframeOut(let id, let delta) where id == kf.id:
                let clamped = max(delta, -(width - 1))
                width += clamped
            default:
                break
            }

            keyframeLayouts.append(EffectKeyframeLayout(
                id: kf.id,
                kind: kf.kind,
                origin: kf.origin,
                frame: CGRect(x: xAbs, y: effectsLaneY, width: width, height: effectsLaneHeight)
            ))
        }
        let effectsLane = EffectsLaneLayout(
            headerFrame: effectsHeader,
            laneFrame: effectsLaneRect,
            keyframes: keyframeLayouts
        )

        return TimelineLayout(
            totalContentWidth: totalContentWidth,
            totalContentHeight: totalContentHeight,
            tracks: tracks,
            effectsLane: effectsLane,
            rulerHeight: rulerHeight,
            trackHeaderWidth: trackHeaderWidth
        )
    }

    /// Maps a viewport-space x coordinate to a timeline-domain time. Used
    /// by gesture handlers (option-click split, ruler-click scrub) to
    /// compute "what time on the project's timeline did the user click?"
    /// from a raw mouse coordinate.
    ///
    /// `x` is in the same coordinate space as `TrackLayout.headerFrame`
    /// and `TrackLayout.laneFrame` (origin at the timeline NSView's
    /// top-left). The track-header column maps to negative timeline time
    /// — clicks landing there return 0 clamped at the floor.
    public static func timelineSeconds(forViewportX x: CGFloat, viewport: TimelineViewport) -> CGFloat {
        let pps = max(minPixelsPerSecond, min(maxPixelsPerSecond, viewport.pixelsPerSecond))
        let xInLane = x - trackHeaderWidth
        let seconds = xInLane / pps + viewport.scrollX
        return max(0, seconds)
    }

    /// Inverse of `timelineSeconds(forViewportX:viewport:)`. Used by the
    /// playhead overlay to compute its x position from the player's
    /// current time. Same `pps` clamping so the playhead stays in sync
    /// with the clip frames at the boundary zoom levels.
    public static func viewportX(forTimelineSeconds seconds: CGFloat, viewport: TimelineViewport) -> CGFloat {
        let pps = max(minPixelsPerSecond, min(maxPixelsPerSecond, viewport.pixelsPerSecond))
        return trackHeaderWidth + (seconds - viewport.scrollX) * pps
    }

    /// Sum of the project's longest track duration — used as the timeline's
    /// total length for scroll-bar sizing. Empty projects return 0.
    public static func totalSeconds(in project: Project) -> CGFloat {
        var maxEnd: CGFloat = 0
        for track in project.tracks {
            for clip in track.clips {
                let end = seconds(clip.timelineRange.start) + seconds(clip.timelineRange.duration)
                if end > maxEnd { maxEnd = end }
            }
        }
        return maxEnd
    }

    /// Natural content size of the timeline for the given project + zoom +
    /// trackHeight. Used by the SwiftUI host (`ProjectView`) to size the
    /// NSViewRepresentable's frame so the enclosing `ScrollView` knows the
    /// scrollable extent. Without this, SwiftUI thinks the content is the
    /// minHeight floor, the NSView grows past it via `setFrameSize` from
    /// inside `layout()`, and `defaultScrollAnchor(.topLeading)` re-anchors
    /// on every content-size pulse — producing the "ruler scrolls back out
    /// of view" snap.
    public static func contentSize(
        for project: Project,
        pixelsPerSecond: CGFloat,
        trackHeight: CGFloat
    ) -> CGSize {
        let pps = max(minPixelsPerSecond, min(maxPixelsPerSecond, pixelsPerSecond))
        let trackH = max(minTrackHeight, min(maxTrackHeight, trackHeight))
        let width = trackHeaderWidth + totalSeconds(in: project) * pps
        let height = rulerHeight + verticalInset
            + CGFloat(project.tracks.count) * (trackH + trackSpacing)
            + effectsLaneHeight + trackSpacing
            + verticalInset
        return CGSize(width: width, height: height)
    }

    /// Picks a major + minor tick interval (in seconds) that fits the
    /// current zoom. Major ticks carry a label; minor ticks are short
    /// hash marks between them. Algorithm: pick the smallest "nice"
    /// interval such that one major tick consumes at least
    /// `minMajorPixels` of horizontal space (so labels don't overlap).
    /// Then pick the largest sub-interval still wide enough to render
    /// (≥ 6pt). At extreme zoom the minor interval collapses into the
    /// major (no in-between hashes).
    public static func niceTickInterval(forPixelsPerSecond pps: CGFloat) -> (major: Double, minor: Double) {
        let pps = max(minPixelsPerSecond, min(maxPixelsPerSecond, pps))
        let minMajorPx: CGFloat = 60
        let minMinorPx: CGFloat = 6
        // 1-2-5 progression in seconds. Spans frame-level (0.1s ≈ 6 frames @ 60fps)
        // up to ten-minute markers for very long zoomed-out projects.
        let candidates: [Double] = [
            0.05, 0.1, 0.2, 0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300, 600
        ]
        let major = candidates.first(where: { Double(pps) * $0 >= Double(minMajorPx) }) ?? candidates.last!
        // Find the largest candidate strictly less than `major` whose pixel
        // width is still readable (≥ minMinorPx). If none qualifies, the
        // ruler renders only major ticks.
        let minor = candidates.last(where: { $0 < major && Double(pps) * $0 >= Double(minMinorPx) }) ?? major
        return (major, minor)
    }

    private static func seconds(_ time: RationalTime) -> CGFloat {
        guard time.timescale != 0 else { return 0 }
        return CGFloat(time.value) / CGFloat(time.timescale)
    }
}
