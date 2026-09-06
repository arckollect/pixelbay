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
    /// Grouped timeline display rows — Video, Audio, Effects — in top-down
    /// order. `tracks` and `effectsLane` are still emitted in full so the
    /// per-physical-track hit-test and clip rendering keep working.
    public var displayRows: [TimelineDisplayRow]
    /// One entry per grouped row whose primary clip overlaps a secondary
    /// track's clip. The renderer paints a small camera/speaker badge on
    /// the primary clip's top-right corner to signal that the row carries
    /// a second source there. Empty when no secondary overlap exists.
    public var groupedOverlapBadges: [GroupedLaneBadge]
    /// One per resizable display row (everything except the fixed-height
    /// effects lane): a horizontal grab zone spanning the header column at
    /// the row's bottom edge. Dragging it resizes just that row (per-row
    /// height override); the global track-height slider resets all rows.
    public var rowResizeHandles: [RowResizeHandle]

    public init(
        totalContentWidth: CGFloat,
        totalContentHeight: CGFloat,
        tracks: [TrackLayout],
        effectsLane: EffectsLaneLayout,
        rulerHeight: CGFloat,
        trackHeaderWidth: CGFloat,
        displayRows: [TimelineDisplayRow] = [],
        groupedOverlapBadges: [GroupedLaneBadge] = [],
        rowResizeHandles: [RowResizeHandle] = []
    ) {
        self.totalContentWidth = totalContentWidth
        self.totalContentHeight = totalContentHeight
        self.tracks = tracks
        self.effectsLane = effectsLane
        self.rulerHeight = rulerHeight
        self.trackHeaderWidth = trackHeaderWidth
        self.displayRows = displayRows
        self.groupedOverlapBadges = groupedOverlapBadges
        self.rowResizeHandles = rowResizeHandles
    }
}

/// A per-row height-resize grab zone. `rowID` matches
/// `TimelineDisplayRow.id` ("group:video", "group:audio"); `hitFrame`
/// spans the header column at the row's bottom boundary; `currentHeight`
/// is the row's height at layout time (the drag's starting value).
public struct RowResizeHandle: Sendable, Equatable {
    public let rowID: String
    public let hitFrame: CGRect
    public let currentHeight: CGFloat
    public init(rowID: String, hitFrame: CGRect, currentHeight: CGFloat) {
        self.rowID = rowID
        self.hitFrame = hitFrame
        self.currentHeight = currentHeight
    }
}

/// One row the renderer draws. The layout emits exactly one Video row
/// (when any video track exists), one Audio row (when any audio track
/// exists), and the Effects row — every physical track folds into its
/// group's row and the primary track's clips form the visible band.
public struct TimelineDisplayRow: Sendable, Equatable, Identifiable {
    public enum Kind: Sendable, Equatable {
        /// The `LaneGroupID.video` row. `physicalTracks` lists
        /// every screen / webcam / overlay track that maps into the
        /// group, in project-order. `primaryTrackID` is the screen
        /// track (or the first physical track if no screen-kind track
        /// is present — handles future overlay-only projects).
        case groupedVideo(physicalTracks: [TrackID], primaryTrackID: TrackID)
        /// The `LaneGroupID.audio` row. `primaryTrackID` is
        /// the microphone (or first physical track if no mic is
        /// present — voiceover-only projects).
        case groupedAudio(physicalTracks: [TrackID], primaryTrackID: TrackID)
        /// The dedicated effects lane (read-only badges).
        case effectsLane
    }

    /// Identifier suitable for `Identifiable` consumers (List, ForEach).
    /// String-typed so the same value space covers track-IDs, lane-group
    /// rawValues, and the fixed `effects` token.
    public let id: String
    public let kind: Kind
    public let height: CGFloat

    public init(id: String, kind: Kind, height: CGFloat) {
        self.id = id
        self.kind = kind
        self.height = height
    }
}

extension TimelineDisplayRow.Kind {
    /// True iff this row is the Video grouped lane. Used by the renderer
    /// to pick the camera-vs-speaker badge glyph.
    public var isVideoGroup: Bool {
        if case .groupedVideo = self { return true }
        return false
    }
}

/// A "there's also content on a secondary track here" indicator. The
/// renderer paints a small icon-on-circle (camera for video group,
/// speaker for audio group) anchored to the top-right of `anchorFrame`
/// to signal that a webcam / system-audio clip underlies this span of
/// the row. Per-primary-clip de-duplicated — at most one badge per
/// primary clip even when multiple secondary tracks overlap it.
public struct GroupedLaneBadge: Sendable, Equatable {
    public enum Kind: Sendable, Equatable { case video; case audio }
    public let kind: Kind
    /// Frame of the primary clip the badge anchors against, in viewport
    /// coordinates (same space as `ClipLayout.frame`).
    public let anchorFrame: CGRect
    /// ID of the primary clip the badge attaches to — useful for tests
    /// that want to assert "badge appeared on screen clip X".
    public let primaryClipID: ClipID
    public init(kind: Kind, anchorFrame: CGRect, primaryClipID: ClipID) {
        self.kind = kind
        self.anchorFrame = anchorFrame
        self.primaryClipID = primaryClipID
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
    /// Per-row height overrides keyed by `TimelineDisplayRow.id`. Rows
    /// absent from the map use `trackHeight`. Set by dragging a row's
    /// header bottom edge; cleared when the user moves the global
    /// track-height slider.
    public var rowHeightOverrides: [String: CGFloat]

    public init(
        size: CGSize,
        pixelsPerSecond: CGFloat,
        scrollX: CGFloat = 0,
        trackHeight: CGFloat = TimelineLayoutCalculator.defaultTrackHeight,
        rowHeightOverrides: [String: CGFloat] = [:]
    ) {
        self.size = size
        self.pixelsPerSecond = pixelsPerSecond
        self.scrollX = scrollX
        self.trackHeight = trackHeight
        self.rowHeightOverrides = rowHeightOverrides
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
    /// Editor default when the preview should own more vertical space while
    /// keeping timeline labels and thumbnails usable.
    public static let compactTrackHeight: CGFloat = 36
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
    /// Low enough that long recordings (many minutes) can fit-to-width in
    /// a normal window — the editor's default zoom fits the whole project
    /// (see ProjectView.fitTimelineZoomIfNeeded). Was 16, which capped
    /// "fit" at ~80 seconds for a typical lane width.
    public static let minPixelsPerSecond: CGFloat = 2
    public static let maxPixelsPerSecond: CGFloat = 800
    /// Effects row sits below all real tracks. Thinner than a regular
    /// track lane because each keyframe is a single rounded badge, not a
    /// scrubbable clip body with a waveform overlay.
    public static let effectsLaneHeight: CGFloat = 28

    /// Pure-function grouping pass: produces the row sequence the
    /// renderer iterates top-down. Each physical track folds into its
    /// `TrackKind.laneGroup` row (Video or Audio); the `.effects` track
    /// folds into the dedicated `effectsLane` row.
    ///
    /// Stable ordering rules:
    ///   • Video group appears before Audio group when both are
    ///     present (video on top).
    ///   • Within a group, `physicalTracks` keeps `project.tracks` order.
    ///   • `effectsLane` always sits at the bottom.
    public static func computeDisplayRows(
        project: Project,
        trackHeight: CGFloat = defaultTrackHeight,
        rowHeightOverrides: [String: CGFloat] = [:]
    ) -> [TimelineDisplayRow] {
        let trackH = max(minTrackHeight, min(maxTrackHeight, trackHeight))
        // Per-row override wins over the uniform slider height; clamped to
        // the same bounds so a drag can't collapse a row to nothing.
        func rowHeight(forID id: String) -> CGFloat {
            guard let override = rowHeightOverrides[id] else { return trackH }
            return max(minTrackHeight, min(maxTrackHeight, override))
        }
        // Bucket physical tracks by their lane group, preserving the
        // project's track ordering inside each bucket.
        var videoIDs: [TrackID] = []
        var audioIDs: [TrackID] = []
        var primaryVideo: TrackID?    // prefer screen, fall back to first video track
        var primaryAudio: TrackID?    // prefer microphone, fall back to first audio track
        for track in project.tracks {
            switch track.kind.laneGroup {
            case .video:
                videoIDs.append(track.id)
                if primaryVideo == nil && track.kind == .screen {
                    primaryVideo = track.id
                }
            case .audio:
                audioIDs.append(track.id)
                if primaryAudio == nil && track.kind == .microphone {
                    primaryAudio = track.id
                }
            case .none:
                // .effects — handled by the dedicated effectsLane row.
                break
            }
        }
        if primaryVideo == nil { primaryVideo = videoIDs.first }
        if primaryAudio == nil { primaryAudio = audioIDs.first }

        var rows: [TimelineDisplayRow] = []
        let appendGroup: (LaneGroupID, [TrackID], TrackID?) -> Void = { group, ids, primary in
            guard !ids.isEmpty, let primary else { return }
            let kind: TimelineDisplayRow.Kind = (group == .video)
                ? .groupedVideo(physicalTracks: ids, primaryTrackID: primary)
                : .groupedAudio(physicalTracks: ids, primaryTrackID: primary)
            let id = "group:\(group.rawValue)"
            rows.append(TimelineDisplayRow(id: id, kind: kind, height: rowHeight(forID: id)))
        }
        appendGroup(.video, videoIDs, primaryVideo)
        appendGroup(.audio, audioIDs, primaryAudio)

        // Effects lane is always last, always present, fixed height.
        rows.append(TimelineDisplayRow(id: "effects", kind: .effectsLane, height: effectsLaneHeight))
        return rows
    }

    public static func layout(
        project: Project,
        viewport: TimelineViewport,
        dragPreview: TimelineDragPreview = .none
    ) -> TimelineLayout {
        let pps = max(minPixelsPerSecond, min(maxPixelsPerSecond, viewport.pixelsPerSecond))
        let trackHeight = max(minTrackHeight, min(maxTrackHeight, viewport.trackHeight))
        let totalSeconds = self.totalSeconds(in: project)
        let totalContentWidth = trackHeaderWidth + max(viewport.size.width - trackHeaderWidth, totalSeconds * pps)

        // Y positions are driven by `displayRows` so grouped tracks share
        // a single row. Build a TrackID → row-Y map first; per-track
        // frames are projected onto that map below.
        let displayRows = computeDisplayRows(
            project: project,
            trackHeight: trackHeight,
            rowHeightOverrides: viewport.rowHeightOverrides
        )
        var trackToRowY: [TrackID: CGFloat] = [:]
        var trackToRowHeight: [TrackID: CGFloat] = [:]
        var effectsLaneY: CGFloat = rulerHeight + verticalInset
        var cumulativeY: CGFloat = rulerHeight + verticalInset
        var resizeHandles: [RowResizeHandle] = []
        for row in displayRows {
            switch row.kind {
            case .groupedVideo(let physicalTracks, _),
                 .groupedAudio(let physicalTracks, _):
                // All physical tracks in the group share this row's Y.
                for trackID in physicalTracks {
                    trackToRowY[trackID] = cumulativeY
                    trackToRowHeight[trackID] = row.height
                }
            case .effectsLane:
                effectsLaneY = cumulativeY
            }
            // Every resizable row gets a grab zone across the header column
            // at its bottom boundary (covering the inter-row gap plus a
            // little slack each side). The effects lane stays fixed-height.
            if row.kind != .effectsLane {
                resizeHandles.append(RowResizeHandle(
                    rowID: row.id,
                    hitFrame: CGRect(
                        x: 0,
                        y: cumulativeY + row.height - 2,
                        width: trackHeaderWidth,
                        height: trackSpacing + 4
                    ),
                    currentHeight: row.height
                ))
            }
            cumulativeY += row.height + trackSpacing
        }
        // `cumulativeY` now sits just past the effects row's spacing —
        // the closing verticalInset is added below.
        let totalContentHeight = cumulativeY - trackSpacing + verticalInset

        var tracks: [TrackLayout] = []
        for track in project.tracks {
            // `.effects` tracks fold into the dedicated effects lane —
            // skip them here so they don't get drawn twice.
            if track.kind == .effects { continue }
            guard let yOrigin = trackToRowY[track.id] else { continue }
            let rowHeight = trackToRowHeight[track.id] ?? trackHeight
            let header = CGRect(x: 0, y: yOrigin, width: trackHeaderWidth, height: rowHeight)
            let laneOriginX = trackHeaderWidth
            let laneWidth = totalContentWidth - trackHeaderWidth
            let lane = CGRect(x: laneOriginX, y: yOrigin, width: laneWidth, height: rowHeight)

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
                    // Strict snap at timeline-start (t=0): a leftward drag
                    // can move the clip at most by its current start in
                    // pixels. The eventual `MoveClipCommand` rejects
                    // newTimelineStart < 0; clamping the preview keeps
                    // the visible drag in sync with what'll commit.
                    let minDelta = -CGFloat(clipStartSec) * pps
                    xAbs += max(delta, minDelta)
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
                    frame: CGRect(x: xAbs, y: yOrigin, width: width, height: rowHeight)
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
                // Strict snap at t=0 (matches the mouseUp clamp in
                // TimelineView for moveEffect, which is
                // `max(0, oldStart + deltaSeconds)`).
                let minDelta = -CGFloat(startSec) * pps
                xAbs += max(delta, minDelta)
            case .trimEffectKeyframeIn(let id, let delta) where id == kf.id:
                let minDelta = -CGFloat(startSec) * pps
                let clamped = min(max(delta, minDelta), width - 1)
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

        // One badge per primary clip that overlaps any secondary track's
        // clip in a grouped row. Pure-function so tests can drive it
        // directly without touching the NSView.
        let tracksByID = Dictionary(
            tracks.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var badges: [GroupedLaneBadge] = []
        for row in displayRows {
            let physicalTracks: [TrackID]
            let primaryID: TrackID
            let badgeKind: GroupedLaneBadge.Kind
            switch row.kind {
            case .groupedVideo(let pts, let primary):
                physicalTracks = pts; primaryID = primary; badgeKind = .video
            case .groupedAudio(let pts, let primary):
                physicalTracks = pts; primaryID = primary; badgeKind = .audio
            default:
                continue
            }
            guard let primaryLayout = tracksByID[primaryID] else { continue }
            var covered = Set<ClipID>()
            for trackID in physicalTracks where trackID != primaryID {
                guard let secondary = tracksByID[trackID] else { continue }
                for secondaryClip in secondary.clips {
                    for primaryClip in primaryLayout.clips where !covered.contains(primaryClip.id) {
                        if primaryClip.frame.intersects(secondaryClip.frame) {
                            badges.append(GroupedLaneBadge(
                                kind: badgeKind,
                                anchorFrame: primaryClip.frame,
                                primaryClipID: primaryClip.id
                            ))
                            covered.insert(primaryClip.id)
                        }
                    }
                }
            }
        }

        return TimelineLayout(
            totalContentWidth: totalContentWidth,
            totalContentHeight: totalContentHeight,
            tracks: tracks,
            effectsLane: effectsLane,
            rulerHeight: rulerHeight,
            trackHeaderWidth: trackHeaderWidth,
            displayRows: displayRows,
            groupedOverlapBadges: badges,
            rowResizeHandles: resizeHandles
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
        trackHeight: CGFloat,
        rowHeightOverrides: [String: CGFloat] = [:]
    ) -> CGSize {
        let pps = max(minPixelsPerSecond, min(maxPixelsPerSecond, pixelsPerSecond))
        let trackH = max(minTrackHeight, min(maxTrackHeight, trackHeight))
        let width = trackHeaderWidth + totalSeconds(in: project) * pps
        // Branch B: total height follows the display-row sequence (one
        // row per grouped lane when collapsed, one per physical track
        // when expanded, plus the effects lane). Falls back to the old
        // "track-per-row" calculation when project has no tracks.
        let displayRows = computeDisplayRows(
            project: project,
            trackHeight: trackH,
            rowHeightOverrides: rowHeightOverrides
        )
        var cumulative: CGFloat = rulerHeight + verticalInset
        for row in displayRows {
            cumulative += row.height + trackSpacing
        }
        let height = cumulative - trackSpacing + verticalInset
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
        guard let largestCandidate = candidates.last else {
            return (1, 1)
        }
        let major = candidates.first(where: { Double(pps) * $0 >= Double(minMajorPx) }) ?? largestCandidate
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
