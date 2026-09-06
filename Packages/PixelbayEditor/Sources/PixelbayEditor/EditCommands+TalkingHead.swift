import Foundation
import PixelbayCore

// Talking-head effect creation. The compositor has rendered
// `.talkingHeadSwap` keyframes since Phase 3b (the webcam crossfades in over
// the full screen frame while the keyframe is active — see
// `EffectEvaluator.applyTalkingHead`), but nothing authored one until now.
// This is the user-facing route: "make the webcam full-frame for a stretch
// of the recording" is an effect on the Effects row, not a separate timeline
// track — the timeline stays at Video / Audio / Effects.

/// Inserts one `.talkingHeadSwap` keyframe starting at the playhead. Mirrors
/// `AddZoomAtPlayheadCommand` (same insertionConflict-then-apply contract so
/// the inspector can pre-check and its status row never lies), with two
/// differences that fit the effect:
///   • The envelope is longer (a talking-head aside is seconds, not a 0.6s
///     zoom beat) and is **clamped to the timeline end** instead of refusing
///     to insert — the user then trims it on the Effects row.
///   • It refuses only when the recording has no webcam (nothing to swap
///     in), when too little timeline remains, or when the playhead is
///     already inside another talking head. Overlapping a zoom is allowed:
///     the compositor applies both and the full-opacity webcam simply
///     covers the zoomed screen.
public struct AddTalkingHeadAtPlayheadCommand: EditCommand {
    public let displayName = "Add Talking Head"
    public let timelineTime: Double
    public let easeIn: Double
    public let holdDuration: Double
    public let easeOut: Double
    public let timelineDuration: Double?

    /// Shortest segment worth inserting when clamping against the timeline
    /// end — below this the crossfades would eat the whole keyframe.
    public static let minimumDuration: Double = 0.5
    public static let defaultEaseIn: Double = 0.4
    public static let defaultHoldDuration: Double = 3.0
    public static let defaultEaseOut: Double = 0.4

    public init(
        timelineTime: Double,
        easeIn: Double = AddTalkingHeadAtPlayheadCommand.defaultEaseIn,
        holdDuration: Double = AddTalkingHeadAtPlayheadCommand.defaultHoldDuration,
        easeOut: Double = AddTalkingHeadAtPlayheadCommand.defaultEaseOut,
        timelineDuration: Double? = nil
    ) {
        self.timelineTime = timelineTime
        self.easeIn = max(0.05, easeIn)
        self.holdDuration = max(0.1, holdDuration)
        self.easeOut = max(0.05, easeOut)
        self.timelineDuration = timelineDuration
    }

    /// Requested envelope length before any end-of-timeline clamp.
    public var requestedDuration: Double { easeIn + holdDuration + easeOut }

    /// The range this command inserts: starts at the (non-negative) playhead
    /// and runs for `requestedDuration`, shortened to fit the timeline when
    /// a duration is known.
    public var projectedRange: TimeRange {
        let start = max(0, timelineTime)
        var duration = requestedDuration
        if let timelineDuration {
            duration = min(duration, timelineDuration - start)
        }
        return TimeRange(start: .seconds(start), duration: .seconds(max(0, duration)))
    }

    /// Human-readable reason this talking head can't be inserted, or `nil`.
    /// Shared by `apply` (throws) and the inspector button (disables /
    /// reports) so the two can't disagree.
    public func insertionConflict(in project: Project) -> String? {
        let hasWebcam = project.tracks.contains { $0.kind == .webcam && !$0.clips.isEmpty }
        if !hasWebcam {
            return "recording has no webcam to show"
        }
        if projectedRange.duration.seconds < Self.minimumDuration {
            return "not enough timeline left for a talking head"
        }
        let overlap = project.effects.contains {
            $0.kind == .talkingHeadSwap && $0.timelineRange.overlaps(projectedRange)
        }
        if overlap {
            return "playhead is inside an existing talking head"
        }
        return nil
    }

    @discardableResult
    public func apply(to project: inout Project) throws -> any EditCommand {
        if let reason = insertionConflict(in: project) {
            throw EditError.invalidTimelineRange(reason: reason)
        }
        // Zoom params are ignored for this kind (see EffectKeyframe docs);
        // the init defaults are fine. `strength(at:)` scales the eases down
        // proportionally if an end-clamped range is shorter than their sum.
        let keyframe = EffectKeyframe(
            kind: .talkingHeadSwap,
            timelineRange: projectedRange,
            easeIn: .seconds(easeIn),
            easeOut: .seconds(easeOut),
            origin: .manualHotkey
        )
        project.effects.append(keyframe)
        return RemoveEffectKeyframeCommand(keyframeID: keyframe.id)
    }
}
