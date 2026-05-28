import CoreGraphics
import Foundation
import PixelbayCore

// Hit-test results in the timeline's coordinate space. Pure-data so the
// gesture handler in TimelineNSView can be exercised with synthetic points
// without spinning up an NSView.
public enum TimelineHit: Sendable, Equatable {
    /// Click landed on a track header (left column). May trigger track-
    /// level UI later (mute / hide / rename); v0.1 just selects the track.
    case trackHeader(TrackID)
    /// Click landed on the body of a clip — drag begins a Move.
    case clipBody(ClipID, TrackID)
    /// Click landed on the left edge of a clip — drag begins a TrimIn.
    /// Width: `TimelineHitTest.edgeZoneWidth` (6pt) inset from the clip
    /// frame's left side.
    case clipLeftEdge(ClipID, TrackID)
    /// Click landed on the right edge of a clip — drag begins a TrimOut.
    case clipRightEdge(ClipID, TrackID)
    /// Click landed in empty lane area (no clip there). Phase 4: drag to
    /// create new overlay clips.
    case emptyLane(TrackID)
    /// Click landed in the ruler area. Phase 3: drag to scrub the playhead.
    case ruler
    /// Click landed on the effects-lane header (left column). Selects no
    /// keyframe; reserved for future per-lane controls.
    case effectsLaneHeader
    /// Click landed on the body of an effect keyframe — drag begins a Move.
    case effectKeyframeBody(EffectKeyframeID)
    /// Click landed on the left edge of an effect keyframe — drag begins
    /// a TrimIn (shifts start, preserves end).
    case effectKeyframeLeftEdge(EffectKeyframeID)
    /// Click landed on the right edge of an effect keyframe — drag begins
    /// a TrimOut (preserves start, shifts end).
    case effectKeyframeRightEdge(EffectKeyframeID)
    /// Click landed in empty area of the effects lane. ⌥-click on this
    /// inserts a new keyframe at the click time via `AddEffectKeyframeCommand`.
    case emptyEffectsLane
    /// Branch B (Slice B.4) — click landed on a grouped lane's
    /// disclosure triangle (the chevron at the left of the lane
    /// header). Toggles the lane between collapsed and expanded via
    /// `SetLaneCollapsedCommand`. Only emitted for `groupedVideo` /
    /// `groupedAudio` display rows OR for expanded `singleTrack` rows
    /// inside a group (the child row's chevron collapses back).
    case laneDisclosure(LaneGroupID)
    /// Click landed outside any meaningful area (e.g. negative scroll
    /// region, far-right beyond all clips). Treat as deselect.
    case empty
}

public enum TimelineHitTest {
    /// How wide the trim-handle zones are at each edge of a clip's frame.
    /// 6pt is comfortable for mouse + trackpad without making the body
    /// feel tiny on short clips. Phase 4 may scale this with zoom.
    public static let edgeZoneWidth: CGFloat = 6

    /// Returns what's at `point` (timeline-view coordinates) given a layout.
    /// Order of precedence: ruler → lane disclosure → track header → clip
    /// edges → clip body → empty lane → effects-lane header → effect-
    /// keyframe edges → effect-keyframe body → empty effects lane → nothing.
    public static func hit(at point: CGPoint, in layout: TimelineLayout) -> TimelineHit {
        // Ruler is the strip across the top.
        if point.y >= 0 && point.y < layout.rulerHeight {
            return .ruler
        }
        // Branch B (Slice B.4) — lane disclosure triangles sit in the
        // header column at the left edge of each grouped lane row.
        // Check before track-header so the chevron tap wins over a
        // header-area tap.
        for disclosure in layout.laneDisclosures {
            if disclosure.hitFrame.contains(point) {
                return .laneDisclosure(disclosure.groupID)
            }
        }
        // Each track contributes a header cell + a lane cell.
        for track in layout.tracks {
            if track.headerFrame.contains(point) {
                return .trackHeader(track.id)
            }
            if track.laneFrame.contains(point) {
                // Test clips back-to-front so an overlapping clip on top wins.
                for clip in track.clips.reversed() {
                    guard clip.frame.contains(point) else { continue }
                    // Edge zones only apply if the clip is wide enough to
                    // distinguish them from the body — for clips narrower
                    // than 3 × edgeZoneWidth, the entire clip is body so
                    // the user has something draggable rather than two
                    // overlapping trim handles.
                    let clipFrame = clip.frame
                    if clipFrame.width >= edgeZoneWidth * 3 {
                        if point.x - clipFrame.minX <= edgeZoneWidth {
                            return .clipLeftEdge(clip.id, track.id)
                        }
                        if clipFrame.maxX - point.x <= edgeZoneWidth {
                            return .clipRightEdge(clip.id, track.id)
                        }
                    }
                    return .clipBody(clip.id, track.id)
                }
                return .emptyLane(track.id)
            }
        }
        let effectsLane = layout.effectsLane
        if effectsLane.headerFrame.contains(point) {
            return .effectsLaneHeader
        }
        if effectsLane.laneFrame.contains(point) {
            for keyframe in effectsLane.keyframes.reversed() {
                guard keyframe.frame.contains(point) else { continue }
                let kfFrame = keyframe.frame
                if kfFrame.width >= edgeZoneWidth * 3 {
                    if point.x - kfFrame.minX <= edgeZoneWidth {
                        return .effectKeyframeLeftEdge(keyframe.id)
                    }
                    if kfFrame.maxX - point.x <= edgeZoneWidth {
                        return .effectKeyframeRightEdge(keyframe.id)
                    }
                }
                return .effectKeyframeBody(keyframe.id)
            }
            return .emptyEffectsLane
        }
        return .empty
    }
}
