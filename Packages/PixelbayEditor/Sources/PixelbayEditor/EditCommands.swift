import Foundation
import PixelbayCore
import PixelbayInputCapture

// Phase 2 v0.1 starter set — three commands covering trim and per-clip
// volume. The remaining op vocabulary (split, remove, insert, move,
// addTrack, setSpeed, setName) is tracked as follow-up commits; the
// command shape these establish carries over without churn.

// MARK: - SetClipVolume

/// Sets the volume of a clip. Phase 2 UI exposes this as a per-clip slider
/// in the Inspector. Volume is `Double`-typed because some users push past
/// 1.0 for boosting quiet recordings; we don't clamp at apply time, only
/// at render time.
public struct SetClipVolumeCommand: EditCommand {
    public let displayName = "Change Clip Volume"
    public let clipID: ClipID
    public let newVolume: Double

    public init(clipID: ClipID, newVolume: Double) {
        self.clipID = clipID
        self.newVolume = newVolume
    }

    @discardableResult
    public func apply(to project: inout Project) throws -> any EditCommand {
        guard newVolume >= 0 else { throw EditError.invalidVolume(value: newVolume) }
        var previousVolume: Double = 1.0
        try project.mutateClip(clipID) { clip in
            previousVolume = clip.volume
            clip.volume = newVolume
        }
        return SetClipVolumeCommand(clipID: clipID, newVolume: previousVolume)
    }
}

// MARK: - TrimClipIn

/// Drags the IN-point of a clip — moves both `sourceRange.start` and
/// `timelineRange.start` by the same delta, keeping the clip's tail
/// anchored. This is the operation HANDOFF §5 / Phase 2 calls out as the
/// "drag clip edges back out" feature: because `sourceRange` is
/// independent of the underlying media file's natural duration, the user
/// can drag the in-point INTO previously-trimmed material as long as the
/// new start is ≥ 0 and ≤ the current `sourceRange.end`.
///
/// `delta` is in the timeline's time domain. Positive delta = trim more
/// (shrinks the clip from the front). Negative delta = expand (drag the
/// edge backward, recovering trimmed material).
public struct TrimClipInCommand: EditCommand {
    public let displayName = "Trim Clip"
    public let clipID: ClipID
    public let delta: RationalTime

    public init(clipID: ClipID, delta: RationalTime) {
        self.clipID = clipID
        self.delta = delta
    }

    @discardableResult
    public func apply(to project: inout Project) throws -> any EditCommand {
        try project.mutateClip(clipID) { clip in
            let newSourceStart = clip.sourceRange.start.adding(delta)
            let newSourceDuration = clip.sourceRange.duration.subtracting(delta)
            let newTimelineStart = clip.timelineRange.start.adding(delta)
            let newTimelineDuration = clip.timelineRange.duration.subtracting(delta)

            guard newSourceStart.value >= 0 else {
                throw EditError.invalidSourceRange(reason: "in-point would go below zero")
            }
            guard newSourceDuration.value > 0 else {
                throw EditError.invalidSourceRange(reason: "would zero or invert source duration")
            }
            guard newTimelineDuration.value > 0 else {
                throw EditError.invalidTimelineRange(reason: "would zero or invert timeline duration")
            }

            clip.sourceRange = TimeRange(start: newSourceStart, duration: newSourceDuration)
            clip.timelineRange = TimeRange(start: newTimelineStart, duration: newTimelineDuration)
        }
        return TrimClipInCommand(clipID: clipID, delta: delta.negated())
    }
}

// MARK: - TrimClipOut

/// Drags the OUT-point of a clip — extends/shrinks both `sourceRange.end`
/// and `timelineRange.end` by `delta` while keeping the head anchored.
/// `delta` is in the timeline's time domain; positive = expand, negative
/// = trim.
public struct TrimClipOutCommand: EditCommand {
    public let displayName = "Trim Clip"
    public let clipID: ClipID
    public let delta: RationalTime

    public init(clipID: ClipID, delta: RationalTime) {
        self.clipID = clipID
        self.delta = delta
    }

    @discardableResult
    public func apply(to project: inout Project) throws -> any EditCommand {
        try project.mutateClip(clipID) { clip in
            let newSourceDuration = clip.sourceRange.duration.adding(delta)
            let newTimelineDuration = clip.timelineRange.duration.adding(delta)

            guard newSourceDuration.value > 0 else {
                throw EditError.invalidSourceRange(reason: "would zero or invert source duration")
            }
            guard newTimelineDuration.value > 0 else {
                throw EditError.invalidTimelineRange(reason: "would zero or invert timeline duration")
            }

            clip.sourceRange = TimeRange(
                start: clip.sourceRange.start,
                duration: newSourceDuration
            )
            clip.timelineRange = TimeRange(
                start: clip.timelineRange.start,
                duration: newTimelineDuration
            )
        }
        return TrimClipOutCommand(clipID: clipID, delta: delta.negated())
    }
}

// MARK: - SetClipSpeed

/// Sets the playback speed of a clip. 1.0 = realtime, 0.5 = half-speed,
/// 2.0 = 2x. HANDOFF §5 calls this out as Phase-2-LAST because it
/// complicates AVMutableComposition's time mapping during export. The
/// model side is just a scalar; the renderer side adjusts how
/// `timelineRange.duration` relates to `sourceRange.duration`.
public struct SetClipSpeedCommand: EditCommand {
    public let displayName = "Change Clip Speed"
    public let clipID: ClipID
    public let newSpeed: Double

    public init(clipID: ClipID, newSpeed: Double) {
        self.clipID = clipID
        self.newSpeed = newSpeed
    }

    /// Sets `clip.speed` AND maintains the model invariant
    /// `timelineRange.duration = sourceRange.duration / speed` so the
    /// renderer can derive the playback rate from the ratio of source
    /// duration to timeline duration. Without this invariant, setting a
    /// 2× speed would leave the clip taking the same timeline space and
    /// `PreviewCompositionBuilder.scaleTimeRange` would produce a no-op.
    ///
    /// Side effect: changing speed changes timeline length, so subsequent
    /// clips on the same track may now overlap or have a gap. Phase 4
    /// follow-up: ripple-edit option to slide neighbours.
    @discardableResult
    public func apply(to project: inout Project) throws -> any EditCommand {
        guard newSpeed > 0 else { throw EditError.invalidSpeed(value: newSpeed) }
        var previousSpeed: Double = 1.0
        try project.mutateClip(clipID) { clip in
            previousSpeed = clip.speed
            clip.speed = newSpeed
            // sourceRange.duration is canonical; timelineRange.duration =
            // sourceRange.duration / speed. We preserve the timescale of
            // the existing timelineRange.duration so RationalTime
            // arithmetic across other commands stays consistent.
            let sourceDurSeconds = Double(clip.sourceRange.duration.value) / Double(clip.sourceRange.duration.timescale)
            let newTimelineDurSeconds = sourceDurSeconds / newSpeed
            let scale = clip.timelineRange.duration.timescale
            let newTimelineDur = RationalTime(
                value: Int64((newTimelineDurSeconds * Double(scale)).rounded()),
                timescale: scale
            )
            clip.timelineRange = TimeRange(
                start: clip.timelineRange.start,
                duration: newTimelineDur
            )
        }
        // Inverse: same command shape with previousSpeed. The inverse
        // recomputes timelineRange.duration the same way, restoring it.
        return SetClipSpeedCommand(clipID: clipID, newSpeed: previousSpeed)
    }
}

// MARK: - MoveClip

/// Moves a clip to a new timeline start position, preserving its
/// duration. Re-sorts the track's clips array to maintain ascending
/// order by timelineRange.start. Source range is unchanged.
public struct MoveClipCommand: EditCommand {
    public let displayName = "Move Clip"
    public let clipID: ClipID
    public let newTimelineStart: RationalTime

    public init(clipID: ClipID, newTimelineStart: RationalTime) {
        self.clipID = clipID
        self.newTimelineStart = newTimelineStart
    }

    @discardableResult
    public func apply(to project: inout Project) throws -> any EditCommand {
        guard newTimelineStart.value >= 0 else {
            throw EditError.invalidTimelineRange(reason: "timeline start must be ≥ 0")
        }
        guard let (t, c) = project.locateClip(clipID) else {
            throw EditError.clipNotFound(clipID)
        }
        let originalStart = project.tracks[t].clips[c].timelineRange.start
        // Mutate the clip's timeline start in-place, then re-sort the track.
        var clip = project.tracks[t].clips.remove(at: c)
        clip.timelineRange = TimeRange(
            start: newTimelineStart,
            duration: clip.timelineRange.duration
        )
        project.tracks[t].insertClipMaintainingOrder(clip)
        return MoveClipCommand(clipID: clipID, newTimelineStart: originalStart)
    }
}

// MARK: - SplitClip + internal merge inverse

/// Splits a clip into two adjacent clips at the given timeline position.
/// The split point must be strictly between the clip's timelineRange
/// boundaries (no zero-duration sides). The original clip is removed and
/// replaced with two new clips (left + right), each with newly-generated
/// IDs. Source range is split proportionally — the left half retains the
/// original sourceRange.start through `sourceRange.start + (splitTime -
/// timelineRange.start)`, the right half starts where the left ended.
///
/// HANDOFF §5 / Phase 2: the killer feature is that "drag clip edges
/// back out" still works on the resulting halves — the underlying media
/// file is never modified, so each half can later expand its sourceRange
/// to recover the trimmed material.
public struct SplitClipCommand: EditCommand {
    public let displayName = "Split Clip"
    public let clipID: ClipID
    public let splitTime: RationalTime

    public init(clipID: ClipID, splitTime: RationalTime) {
        self.clipID = clipID
        self.splitTime = splitTime
    }

    @discardableResult
    public func apply(to project: inout Project) throws -> any EditCommand {
        guard let (t, c) = project.locateClip(clipID) else {
            throw EditError.clipNotFound(clipID)
        }
        let trackID = project.tracks[t].id
        let original = project.tracks[t].clips[c]
        let timelineStart = original.timelineRange.start
        let timelineEnd = original.timelineRange.end
        guard splitTime.value > timelineStart.value && splitTime.value < timelineEnd.value else {
            throw EditError.invalidTimelineRange(reason: "split time must be strictly inside the clip's timeline range")
        }
        let leftDelta = RationalTime(
            value: splitTime.value - timelineStart.value,
            timescale: timelineStart.timescale
        )
        let rightDelta = RationalTime(
            value: timelineEnd.value - splitTime.value,
            timescale: timelineEnd.timescale
        )
        let sourceMidStart = original.sourceRange.start.adding(leftDelta)

        let leftClip = Clip(
            id: ClipID.generate(),
            assetID: original.assetID,
            sourceRange: TimeRange(start: original.sourceRange.start, duration: leftDelta),
            timelineRange: TimeRange(start: timelineStart, duration: leftDelta),
            volume: original.volume,
            speed: original.speed,
            enabled: original.enabled,
            extras: original.extras
        )
        let rightClip = Clip(
            id: ClipID.generate(),
            assetID: original.assetID,
            sourceRange: TimeRange(start: sourceMidStart, duration: rightDelta),
            timelineRange: TimeRange(start: splitTime, duration: rightDelta),
            volume: original.volume,
            speed: original.speed,
            enabled: original.enabled,
            extras: original.extras
        )

        project.tracks[t].clips.remove(at: c)
        project.tracks[t].insertClipMaintainingOrder(leftClip)
        project.tracks[t].insertClipMaintainingOrder(rightClip)

        return _MergeAdjacentClipsCommand(
            trackID: trackID,
            leftID: leftClip.id,
            rightID: rightClip.id,
            restoredClip: original
        )
    }
}

/// Internal-by-convention. The inverse of SplitClip: removes both the
/// left and right halves and inserts the original clip back in their
/// place. Constructed only by SplitClipCommand.apply; not exposed as a
/// user-facing operation. Stays public so it can cross actor boundaries
/// inside EditHistory.
public struct _MergeAdjacentClipsCommand: EditCommand {
    public let displayName = "Split Clip"
    public let trackID: TrackID
    public let leftID: ClipID
    public let rightID: ClipID
    public let restoredClip: Clip

    @discardableResult
    public func apply(to project: inout Project) throws -> any EditCommand {
        guard let trackIdx = project.locateTrack(trackID) else {
            throw EditError.trackNotFound(trackID)
        }
        guard let leftIdx = project.tracks[trackIdx].clips.firstIndex(where: { $0.id == leftID }) else {
            throw EditError.clipNotFound(leftID)
        }
        guard let rightIdx = project.tracks[trackIdx].clips.firstIndex(where: { $0.id == rightID }) else {
            throw EditError.clipNotFound(rightID)
        }
        let splitTime = project.tracks[trackIdx].clips[rightIdx].timelineRange.start
        // Remove right first if it's at a higher index — otherwise removing
        // left shifts right's index.
        let firstRemove = max(leftIdx, rightIdx)
        let secondRemove = min(leftIdx, rightIdx)
        project.tracks[trackIdx].clips.remove(at: firstRemove)
        project.tracks[trackIdx].clips.remove(at: secondRemove)
        project.tracks[trackIdx].insertClipMaintainingOrder(restoredClip)
        return SplitClipCommand(clipID: restoredClip.id, splitTime: splitTime)
    }
}

// MARK: - InsertClip / RemoveClip

/// Inserts an already-formed Clip into the named track. Maintains
/// ordering by timelineRange.start. The caller (UI / drag-drop import
/// handler) is responsible for constructing the Clip with the right
/// sourceRange and timelineRange — this primitive doesn't make
/// assumptions about asset duration or layout.
public struct InsertClipCommand: EditCommand {
    public let displayName = "Insert Clip"
    public let trackID: TrackID
    public let clip: Clip

    public init(trackID: TrackID, clip: Clip) {
        self.trackID = trackID
        self.clip = clip
    }

    @discardableResult
    public func apply(to project: inout Project) throws -> any EditCommand {
        guard let trackIdx = project.locateTrack(trackID) else {
            throw EditError.trackNotFound(trackID)
        }
        if project.tracks[trackIdx].clips.contains(where: { $0.id == clip.id }) {
            throw EditError.invalidTimelineRange(reason: "clip with id \(clip.id.rawValue) already exists on track")
        }
        project.tracks[trackIdx].insertClipMaintainingOrder(clip)
        return RemoveClipCommand(clipID: clip.id)
    }
}

/// Removes a clip. Captures the removed Clip's full state plus the
/// owning track so the inverse (InsertClipCommand) can restore it
/// exactly.
public struct RemoveClipCommand: EditCommand {
    public let displayName = "Remove Clip"
    public let clipID: ClipID

    public init(clipID: ClipID) {
        self.clipID = clipID
    }

    @discardableResult
    public func apply(to project: inout Project) throws -> any EditCommand {
        guard let (t, c) = project.locateClip(clipID) else {
            throw EditError.clipNotFound(clipID)
        }
        let removed = project.tracks[t].clips.remove(at: c)
        let trackID = project.tracks[t].id
        return InsertClipCommand(trackID: trackID, clip: removed)
    }
}

// MARK: - AddTrack / RemoveTrack

/// Appends a track to the project, or inserts at a specific index. The
/// caller passes a fully-formed Track; the inverse path (from
/// RemoveTrackCommand) uses `atIndex` to restore at the original
/// position.
public struct AddTrackCommand: EditCommand {
    public let displayName = "Add Track"
    public let track: Track
    public let atIndex: Int?

    public init(track: Track, atIndex: Int? = nil) {
        self.track = track
        self.atIndex = atIndex
    }

    @discardableResult
    public func apply(to project: inout Project) throws -> any EditCommand {
        if project.tracks.contains(where: { $0.id == track.id }) {
            throw EditError.invalidTimelineRange(reason: "track with id \(track.id.rawValue) already exists")
        }
        let insertIndex: Int
        if let atIndex {
            insertIndex = max(0, min(project.tracks.count, atIndex))
        } else {
            insertIndex = project.tracks.endIndex
        }
        project.tracks.insert(track, at: insertIndex)
        return RemoveTrackCommand(trackID: track.id)
    }
}

/// Removes a track. Captures the removed Track's full state + the
/// original index so AddTrackCommand can restore at the same position.
public struct RemoveTrackCommand: EditCommand {
    public let displayName = "Remove Track"
    public let trackID: TrackID

    public init(trackID: TrackID) {
        self.trackID = trackID
    }

    @discardableResult
    public func apply(to project: inout Project) throws -> any EditCommand {
        guard let trackIdx = project.locateTrack(trackID) else {
            throw EditError.trackNotFound(trackID)
        }
        let removed = project.tracks.remove(at: trackIdx)
        return AddTrackCommand(track: removed, atIndex: trackIdx)
    }
}

// MARK: - RenameProject

public struct RenameProjectCommand: EditCommand {
    public let displayName = "Rename Project"
    public let newName: String

    public init(newName: String) {
        self.newName = newName
    }

    @discardableResult
    public func apply(to project: inout Project) throws -> any EditCommand {
        let previous = project.name
        project.name = newName
        return RenameProjectCommand(newName: previous)
    }
}

// MARK: - Effect keyframes (Phase 3b)

/// Add a new `EffectKeyframe` to `Project.effects`. Inverse removes it
/// by ID.
public struct AddEffectKeyframeCommand: EditCommand {
    public let displayName = "Add Effect"
    public let keyframe: EffectKeyframe

    public init(keyframe: EffectKeyframe) {
        self.keyframe = keyframe
    }

    @discardableResult
    public func apply(to project: inout Project) throws -> any EditCommand {
        if project.effects.contains(where: { $0.id == keyframe.id }) {
            throw EditError.invalidTimelineRange(reason: "duplicate keyframe id")
        }
        // Bounds-check the range — same rule as clips: must be positive
        // duration. The compositor tolerates over-long ranges but the
        // editor refuses zero / negative.
        guard keyframe.timelineRange.duration.value > 0 else {
            throw EditError.invalidTimelineRange(reason: "keyframe duration must be > 0")
        }
        guard keyframe.timelineRange.start.value >= 0 else {
            throw EditError.invalidTimelineRange(reason: "keyframe start must be >= 0")
        }
        project.effects.append(keyframe)
        return RemoveEffectKeyframeCommand(keyframeID: keyframe.id)
    }
}

/// Remove an `EffectKeyframe` by ID. Inverse re-adds the prior value.
public struct RemoveEffectKeyframeCommand: EditCommand {
    public let displayName = "Remove Effect"
    public let keyframeID: EffectKeyframeID

    public init(keyframeID: EffectKeyframeID) {
        self.keyframeID = keyframeID
    }

    @discardableResult
    public func apply(to project: inout Project) throws -> any EditCommand {
        guard let idx = project.effects.firstIndex(where: { $0.id == keyframeID }) else {
            throw EditError.clipNotFound(ClipID(rawValue: keyframeID.rawValue))
        }
        let removed = project.effects.remove(at: idx)
        return _ReinsertEffectKeyframeCommand(keyframe: removed, index: idx)
    }
}

/// Internal inverse for `RemoveEffectKeyframeCommand` — restores at the
/// original index. Not part of the public command vocabulary because the
/// user-driven add command always appends.
struct _ReinsertEffectKeyframeCommand: EditCommand {
    let displayName = "Restore Effect"
    let keyframe: EffectKeyframe
    let index: Int

    @discardableResult
    func apply(to project: inout Project) throws -> any EditCommand {
        let safeIndex = max(0, min(index, project.effects.count))
        project.effects.insert(keyframe, at: safeIndex)
        return RemoveEffectKeyframeCommand(keyframeID: keyframe.id)
    }
}

/// Replace an existing `EffectKeyframe`'s values (kind, range, params).
/// Inverse restores the prior value.
public struct UpdateEffectKeyframeCommand: EditCommand {
    public let displayName = "Edit Effect"
    public let keyframeID: EffectKeyframeID
    public let newValue: EffectKeyframe

    public init(keyframeID: EffectKeyframeID, newValue: EffectKeyframe) {
        self.keyframeID = keyframeID
        self.newValue = newValue
    }

    @discardableResult
    public func apply(to project: inout Project) throws -> any EditCommand {
        guard let idx = project.effects.firstIndex(where: { $0.id == keyframeID }) else {
            throw EditError.clipNotFound(ClipID(rawValue: keyframeID.rawValue))
        }
        guard newValue.timelineRange.duration.value > 0 else {
            throw EditError.invalidTimelineRange(reason: "keyframe duration must be > 0")
        }
        let previous = project.effects[idx]
        // Preserve the original ID even if the caller passed a new one.
        var stamped = newValue
        if stamped.id != keyframeID {
            stamped = EffectKeyframe(
                id: keyframeID,
                kind: newValue.kind,
                timelineRange: newValue.timelineRange,
                zoomFactor: newValue.zoomFactor,
                centerX: newValue.centerX,
                centerY: newValue.centerY,
                easeIn: newValue.easeIn,
                easeOut: newValue.easeOut,
                extras: newValue.extras
            )
        }
        project.effects[idx] = stamped
        return UpdateEffectKeyframeCommand(keyframeID: keyframeID, newValue: previous)
    }
}

// MARK: - GenerateAutoZoomFromClicks (Phase 3b)

/// One click in the timeline's time domain. The caller (typically the app
/// target reading `media/clicks-<sessionID>.json` via `ClicksSidecarStore`
/// from PixelbayInputCapture) is responsible for subtracting the
/// capture-start offset so `timelineTime` is in the same domain as the
/// project's `Clip.timelineRange.start`.
public struct AutoZoomClick: Sendable, Equatable {
    public var timelineTime: Double
    public var centerX: Double       // 0..1 normalized to screen layer
    public var centerY: Double       // 0..1 normalized to screen layer
    /// Mirrors `ZoomMark.source` for manual marks routed through
    /// `GenerateManualZoomsCommand`. Nil for click-sourced auto-zoom (which
    /// has no equivalent source distinction). When set to `.shakeGesture` or
    /// `.circleGesture`, the manual-zoom command emits the keyframe with
    /// `trajectory: nil` so the zoom holds a STATIC anchor on
    /// `(centerX, centerY)` instead of following the cursor through hold +
    /// ease-out (which otherwise jitters with every post-gesture micro-move).
    public var source: ZoomMarkSource?

    public init(
        timelineTime: Double,
        centerX: Double = 0.5,
        centerY: Double = 0.5,
        source: ZoomMarkSource? = nil
    ) {
        self.timelineTime = timelineTime
        self.centerX = centerX
        self.centerY = centerY
        self.source = source
    }
}

/// Generates zoom keyframes from a click list. Each click becomes one
/// `EffectKeyframe` whose timeline range covers (lookahead + hold +
/// easeOut) seconds, with the lookahead used as the ease-in window so the
/// zoom is at full strength exactly at the click time.
///
/// The inverse removes only the keyframes this command added (by ID), so
/// undoing leaves any user-curated keyframes intact.
public struct GenerateAutoZoomFromClicksCommand: EditCommand {
    public let displayName = "Generate Auto-Zoom from Clicks"
    public let clicks: [AutoZoomClick]
    public let lookahead: Double
    public let holdDuration: Double
    public let easeOutDuration: Double
    public let zoomFactor: Double
    public let timelineDuration: Double?     // optional clamp (skip clicks past timeline)
    /// Cap on merged-cluster duration. After a cluster reaches this many
    /// seconds, the next click starts a fresh cluster instead of extending
    /// the current one — keeps a long sequence of related clicks from
    /// snowballing into one ten-second zoom (slice #11.d).
    public let maxClusterDuration: Double
    /// Euclidean distance in normalised screen space (`[0,1]` axes) at which
    /// a new click breaks the running cluster. If the click's focal point
    /// jumps more than this from the cluster's current focal point, treat
    /// it as a new attention area (slice #11.d).
    public let spatialResetThreshold: Double
    /// Optional cursor trajectory (project-timeline-time domain). When set,
    /// each generated keyframe carries the slice of this trajectory covering
    /// its timeline range, so slice-3 per-frame interpolation can follow the
    /// cursor instead of holding the static `(centerX, centerY)`. Nil = the
    /// pre-2026-05-13 fixed-centre behaviour (back-compat for sidecars
    /// written by v0.1 builds that didn't log moves).
    public let mouseTrajectory: [MouseTrajectorySample]?
    private let preGeneratedIDs: [EffectKeyframeID]?

    public init(
        clicks: [AutoZoomClick],
        lookahead: Double = 0.7,
        holdDuration: Double = 1.8,
        easeOutDuration: Double = 0.5,
        zoomFactor: Double = 2.0,
        timelineDuration: Double? = nil,
        maxClusterDuration: Double = 4.5,
        spatialResetThreshold: Double = 0.30,
        mouseTrajectory: [MouseTrajectorySample]? = nil
    ) {
        self.clicks = clicks
        self.lookahead = max(0.05, lookahead)
        self.holdDuration = max(0.1, holdDuration)
        self.easeOutDuration = max(0.05, easeOutDuration)
        self.zoomFactor = max(1.05, zoomFactor)
        self.timelineDuration = timelineDuration
        self.maxClusterDuration = max(lookahead + holdDuration + easeOutDuration, maxClusterDuration)
        self.spatialResetThreshold = max(0.0, spatialResetThreshold)
        self.mouseTrajectory = mouseTrajectory
        self.preGeneratedIDs = nil
    }

    /// Internal initializer used by the inverse path to recreate the
    /// keyframes with the SAME IDs on redo so subsequent undo can target
    /// them. Not part of the public API.
    init(
        clicks: [AutoZoomClick],
        lookahead: Double,
        holdDuration: Double,
        easeOutDuration: Double,
        zoomFactor: Double,
        timelineDuration: Double?,
        maxClusterDuration: Double,
        spatialResetThreshold: Double,
        mouseTrajectory: [MouseTrajectorySample]?,
        preGeneratedIDs: [EffectKeyframeID]
    ) {
        self.clicks = clicks
        self.lookahead = lookahead
        self.holdDuration = holdDuration
        self.easeOutDuration = easeOutDuration
        self.zoomFactor = zoomFactor
        self.timelineDuration = timelineDuration
        self.maxClusterDuration = maxClusterDuration
        self.spatialResetThreshold = spatialResetThreshold
        self.mouseTrajectory = mouseTrajectory
        self.preGeneratedIDs = preGeneratedIDs
    }

    @discardableResult
    public func apply(to project: inout Project) throws -> any EditCommand {
        // Replace-auto-on-regenerate: every existing `.auto` zoom keyframe
        // is removed before generating the new set, so clicking "Generate
        // Auto-Zoom" twice is idempotent. Manual `.manualHotkey` keyframes
        // are preserved — they fence the click stream (see below).
        let previousAutoKeyframes = project.effects.filter { kf in
            kf.kind == .zoom && kf.origin == .auto
        }
        let previousAutoIDs = Set(previousAutoKeyframes.map(\.id))
        if !previousAutoIDs.isEmpty {
            project.effects.removeAll { previousAutoIDs.contains($0.id) }
        }

        // Manual keyframes win: any click whose proposed keyframe range
        // overlaps an existing manual zoom is dropped at generation time,
        // not later by the compositor's pick-one-zoom rule (cleaner edit
        // history + a non-rendered click also can't be merged into a
        // cluster that straddles a manual zoom).
        let manualRanges: [TimeRange] = project.effects
            .filter { $0.kind == .zoom && $0.origin == .manualHotkey }
            .map(\.timelineRange)
        let filteredClicks = filterClicksAgainstManualRanges(clicks, manualRanges: manualRanges)

        let generated = generateKeyframes(from: filteredClicks)
        if !generated.isEmpty {
            project.effects.append(contentsOf: generated)
        }
        // Inverse: swap the new set back out and the previous set back in.
        // A single ⌘Z restores the prior state; a second ⌘Z undoes whatever
        // came before this generation. Symmetric, so redo returns to the
        // newly-generated set with identical IDs.
        return _SwapEffectKeyframesCommand(
            displayName: "Undo Generate Auto-Zoom",
            keyframesToRemove: generated,
            keyframesToInsert: previousAutoKeyframes
        )
    }

    /// Drops clicks whose proposed `[click - lookahead, click + hold + easeOut]`
    /// range overlaps any manual keyframe. Manual zooms remain visible
    /// because the user explicitly placed them; auto clicks landing inside
    /// the manual region would either re-zoom on top of the manual (compound
    /// effect) or — with L4's pick-one rule — fight for which one renders.
    private func filterClicksAgainstManualRanges(
        _ clicks: [AutoZoomClick],
        manualRanges: [TimeRange]
    ) -> [AutoZoomClick] {
        guard !manualRanges.isEmpty else { return clicks }
        let totalPerClick = lookahead + holdDuration + easeOutDuration
        return clicks.filter { click in
            let start = click.timelineTime - lookahead
            // Out-of-bounds clicks get dropped later in generateKeyframes
            // anyway; let them through here so the filter stays focused on
            // the manual-overlap question.
            guard start >= 0 else { return true }
            let range = TimeRange(
                start: .seconds(start),
                duration: .seconds(totalPerClick)
            )
            return !manualRanges.contains { $0.overlaps(range) }
        }
    }

    private func generateKeyframes(from clicks: [AutoZoomClick]) -> [EffectKeyframe] {
        // 1. Filter out clicks that can't fit their full per-click range,
        //    then sort by timelineTime — the cluster walk below assumes
        //    monotonic time.
        let totalPerClick = lookahead + holdDuration + easeOutDuration
        let validClicks = clicks
            .filter { click in
                let start = click.timelineTime - lookahead
                if start < 0 { return false }
                if let timelineDuration, start + totalPerClick > timelineDuration {
                    return false
                }
                return true
            }
            .sorted { $0.timelineTime < $1.timelineTime }

        // 2. Walk sorted clicks. A new click joins the current cluster when
        //    its zoom-in ramp (start = click.timelineTime - lookahead) begins
        //    before the current cluster's ease-out ends. Each merge moves
        //    the cluster's focal point to the latest click's coords so the
        //    user's most recent attention drives the framing, and extends
        //    the cluster's tail to that click's hold + easeOut.
        struct Cluster {
            var firstClickTime: Double
            var lastClick: AutoZoomClick
            var end: Double
        }
        let clusterTail = holdDuration + easeOutDuration
        var clusters: [Cluster] = []
        for click in validClicks {
            let clickStart = click.timelineTime - lookahead
            let clickEnd = click.timelineTime + clusterTail
            let canMerge: Bool
            if let current = clusters.last, clickStart <= current.end {
                // Time-overlap ok — also gate on cluster duration cap (slice
                // #11.d) and spatial reset (focal point jumped too far).
                let extendedDuration = clickEnd - (current.firstClickTime - lookahead)
                let dx = click.centerX - current.lastClick.centerX
                let dy = click.centerY - current.lastClick.centerY
                let spatialDist = (dx * dx + dy * dy).squareRoot()
                canMerge = extendedDuration <= maxClusterDuration
                    && spatialDist <= spatialResetThreshold
            } else {
                canMerge = false
            }

            if canMerge {
                var current = clusters[clusters.count - 1]
                current.lastClick = click
                current.end = clickEnd
                clusters[clusters.count - 1] = current
            } else {
                // Forced split (no time-overlap to begin with, or canMerge=false
                // due to the maxClusterDuration / spatialResetThreshold gates).
                // If the new cluster would start INSIDE the previous cluster's
                // range, truncate the previous to `clickStart` so the two are
                // disjoint — preserves the first cluster's ease-in / hold but
                // cuts its tail. Without this the two emitted keyframes would
                // overlap by `[clickStart, previousEnd]` and the compositor
                // would compound their zoom transforms in that window.
                if var previous = clusters.last, clickStart < previous.end {
                    previous.end = clickStart
                    let previousStart = previous.firstClickTime - lookahead
                    let previousDuration = previous.end - previousStart
                    let minVisibleDuration = lookahead + easeOutDuration + 0.05
                    if previousDuration < minVisibleDuration {
                        clusters.removeLast()
                    } else {
                        clusters[clusters.count - 1] = previous
                    }
                }
                clusters.append(Cluster(
                    firstClickTime: click.timelineTime,
                    lastClick: click,
                    end: clickEnd
                ))
            }
        }

        // 3. Emit one EffectKeyframe per cluster.
        var idIter = preGeneratedIDs?.makeIterator()
        return clusters.map { cluster -> EffectKeyframe in
            let start = cluster.firstClickTime - lookahead
            let duration = cluster.end - start
            let id: EffectKeyframeID
            if let next = idIter?.next() {
                id = next
            } else {
                id = .generate()
            }
            let range = TimeRange(
                start: .seconds(start),
                duration: .seconds(duration)
            )
            let slice = mouseTrajectory.map {
                AutoZoomService.trajectoryWindow($0, timelineRange: range)
            }
            return EffectKeyframe(
                id: id,
                kind: .zoom,
                timelineRange: range,
                zoomFactor: zoomFactor,
                centerX: cluster.lastClick.centerX,
                centerY: cluster.lastClick.centerY,
                easeIn: .seconds(lookahead),
                easeOut: .seconds(easeOutDuration),
                trajectory: slice,
                origin: .auto
            )
        }
    }
}

/// Inverse for `GenerateAutoZoomFromClicksCommand`. Removes a specific set
/// of keyframes by ID; produces a redo that reinserts them. Multi-ID
/// version of the single-ID `RemoveEffectKeyframeCommand` so a single
/// undo / redo round-trip stays one entry on the stack.
struct _RemoveEffectKeyframesByIDCommand: EditCommand {
    let displayName = "Remove Auto-Zoom Keyframes"
    let keyframeIDs: [EffectKeyframeID]

    @discardableResult
    func apply(to project: inout Project) throws -> any EditCommand {
        let idSet = Set(keyframeIDs)
        let removed = project.effects.filter { idSet.contains($0.id) }
        project.effects.removeAll { idSet.contains($0.id) }
        return _ReinsertEffectKeyframesCommand(keyframes: removed)
    }
}

struct _ReinsertEffectKeyframesCommand: EditCommand {
    let displayName = "Restore Auto-Zoom Keyframes"
    let keyframes: [EffectKeyframe]

    @discardableResult
    func apply(to project: inout Project) throws -> any EditCommand {
        project.effects.append(contentsOf: keyframes)
        return _RemoveEffectKeyframesByIDCommand(keyframeIDs: keyframes.map(\.id))
    }
}

/// Symmetric inverse for "regenerate" commands that replace an existing set
/// of keyframes with a freshly-computed one. On apply: remove the
/// `keyframesToRemove` set by ID, append the `keyframesToInsert` set; return
/// an inverse with the two sets swapped. Used by
/// `GenerateAutoZoomFromClicksCommand` so a single ⌘Z restores the previous
/// auto-keyframes that were wiped at apply time.
struct _SwapEffectKeyframesCommand: EditCommand {
    let displayName: String
    let keyframesToRemove: [EffectKeyframe]
    let keyframesToInsert: [EffectKeyframe]

    @discardableResult
    func apply(to project: inout Project) throws -> any EditCommand {
        if !keyframesToRemove.isEmpty {
            let idSet = Set(keyframesToRemove.map(\.id))
            project.effects.removeAll { idSet.contains($0.id) }
        }
        if !keyframesToInsert.isEmpty {
            project.effects.append(contentsOf: keyframesToInsert)
        }
        return _SwapEffectKeyframesCommand(
            displayName: displayName,
            keyframesToRemove: keyframesToInsert,
            keyframesToInsert: keyframesToRemove
        )
    }
}

// MARK: - GenerateManualZooms (slice #11.d)

/// Emits one zoom keyframe per user-stated `AutoZoomClick` (typically sourced
/// from `ClicksSidecar.marks`). Unlike `GenerateAutoZoomFromClicksCommand`,
/// this command does NOT cluster, merge, or filter — the user explicitly
/// asked for a zoom at each timestamp. Every emitted keyframe is tagged
/// `origin = .manualHotkey` so the timeline can paint them distinctly.
///
/// Inverse pattern mirrors the auto-zoom command: collect emitted IDs,
/// remove-by-ID on undo, reinsert-with-state on redo. Manual marks survive
/// undoing the auto generation (and vice versa).
public struct GenerateManualZoomsCommand: EditCommand {
    public let displayName = "Generate Manual Zooms"
    public let marks: [AutoZoomClick]
    public let lookahead: Double
    public let holdDuration: Double
    public let easeOutDuration: Double
    public let zoomFactor: Double
    public let timelineDuration: Double?
    public let mouseTrajectory: [MouseTrajectorySample]?

    public init(
        marks: [AutoZoomClick],
        // Manual zoom defaults are snappier than auto-zoom defaults because
        // the user has already gestured/keyed — they want immediate response
        // and a brief hold, not the 3.0s arc auto-zoom uses for clicks. With
        // gesture-start anchoring (`Detection.timestamp` = window[0]), the
        // 0.3s ease-in covers the gesture motion itself, hold is just long
        // enough to register the focal point, then ease-out releases.
        lookahead: Double = 0.3,
        holdDuration: Double = 0.6,
        easeOutDuration: Double = 0.5,
        zoomFactor: Double = 2.0,
        timelineDuration: Double? = nil,
        mouseTrajectory: [MouseTrajectorySample]? = nil
    ) {
        self.marks = marks
        self.lookahead = max(0.05, lookahead)
        self.holdDuration = max(0.1, holdDuration)
        self.easeOutDuration = max(0.05, easeOutDuration)
        self.zoomFactor = max(1.05, zoomFactor)
        self.timelineDuration = timelineDuration
        self.mouseTrajectory = mouseTrajectory
    }

    @discardableResult
    public func apply(to project: inout Project) throws -> any EditCommand {
        // Replace-manual-on-regenerate: pressing the gestures button a second
        // time wipes and rebuilds. Mirrors the click-button's regen idempotency
        // (`GenerateAutoZoomFromClicksCommand.apply`). Without this, the
        // occupied-range fence below would skip every new mark because the
        // previous run's keyframes still cover the same timestamps.
        let previousManualKeyframes = project.effects.filter { kf in
            kf.kind == .zoom && kf.origin == .manualHotkey
        }
        let previousManualIDs = Set(previousManualKeyframes.map(\.id))
        if !previousManualIDs.isEmpty {
            project.effects.removeAll { previousManualIDs.contains($0.id) }
        }

        let totalDuration = lookahead + holdDuration + easeOutDuration
        // Fence against any remaining zoom keyframes (auto-from-clicks after
        // the manual-wipe above). New marks landing inside an auto cluster
        // are dropped rather than fighting the compositor's single-winner rule.
        var occupiedRanges: [TimeRange] = project.effects
            .filter { $0.kind == .zoom }
            .map(\.timelineRange)
        let sortedMarks = marks.sorted { $0.timelineTime < $1.timelineTime }
        var generated: [EffectKeyframe] = []
        for mark in sortedMarks {
            // Manual marks (⌃⌘Z hotkey, circle gesture, shake gesture) place
            // the zoom range to BEGIN at the mark timestamp rather than peak
            // at it — the user has already gestured / pressed, so the zoom
            // should respond AFTER the input, not ramp up across the gesture
            // motion itself. (Auto-zoom uses lookahead because a click is a
            // single-instant event with no preceding motion to overlap.)
            let start = mark.timelineTime
            if start < 0 { continue }
            if let timelineDuration, start + totalDuration > timelineDuration {
                continue
            }
            let range = TimeRange(
                start: .seconds(start),
                duration: .seconds(totalDuration)
            )
            if occupiedRanges.contains(where: { $0.overlaps(range) }) {
                continue
            }
            // Gesture-sourced marks (shake / circle) want a STATIC zoom
            // anchor: the user motioned to highlight a region, then expects
            // the zoom to lock there even if the cursor wanders. Following
            // the trajectory makes every post-gesture micro-move push the
            // zoom around — exactly the jitter the cursor-shake feature is
            // supposed to avoid. Hotkey marks keep trajectory-follow so a
            // user pressing ⌃⌘Z mid-motion still gets cursor-tracking.
            //
            // Back-compat for v4 sidecars written before the `source` tag
            // existed (mark.source == nil): pre-tag marks were dominantly
            // gesture-sourced in real usage, and the user-visible jitter bug
            // this fix exists to address shows up on exactly those recordings.
            // So treat nil as gesture-equivalent → static anchor. The price
            // is that legacy hotkey-only marks lose trajectory-follow on
            // pre-tag sidecars; an acceptable trade given the alternative is
            // every old gesture recording still jitters until re-recorded.
            let staticAnchor: Bool
            switch mark.source {
            case .shakeGesture, .circleGesture, .none: staticAnchor = true
            case .hotkey: staticAnchor = false
            }
            let slice: [ZoomTrajectorySample]? = staticAnchor
                ? nil
                : mouseTrajectory.map {
                    AutoZoomService.trajectoryWindow($0, timelineRange: range)
                }
            // Phase 3c: snap pinned (gesture) anchors to a 0.05 norm-unit
            // grid (20×20 cells). Kills the sub-cell jitter that motivated
            // the earlier `.pinned + trajectory=nil` defensive patch — gesture
            // samples come in slightly noisy in space, and rounding to a
            // visible cell makes back-to-back captures with the same intent
            // land on the same anchor. Follow-cursor (hotkey) marks are not
            // snapped — they track the live cursor and quantization would
            // read as stepped motion.
            let anchorX = staticAnchor ? (mark.centerX / 0.05).rounded() * 0.05 : mark.centerX
            let anchorY = staticAnchor ? (mark.centerY / 0.05).rounded() * 0.05 : mark.centerY
            // anchorMode: .pinned is the load-bearing part for gesture marks.
            // Setting trajectory: nil alone is NOT enough — at composition
            // build time, `PreviewComposition.applyCursorTrajectory` re-slices
            // the master cursor trajectory onto every zoom keyframe and
            // overwrites the nil. `.pinned` is the signal that survives that
            // step: applyCursorTrajectory + EffectEvaluator.zoomCenter both
            // honour it and keep the static (centerX, centerY) in effect.
            generated.append(EffectKeyframe(
                kind: .zoom,
                timelineRange: range,
                zoomFactor: zoomFactor,
                centerX: anchorX,
                centerY: anchorY,
                easeIn: .seconds(lookahead),
                easeOut: .seconds(easeOutDuration),
                trajectory: slice,
                origin: .manualHotkey,
                anchorMode: staticAnchor ? .pinned : .followCursor
            ))
            occupiedRanges.append(range)
        }
        if !generated.isEmpty {
            project.effects.append(contentsOf: generated)
        }
        return _SwapEffectKeyframesCommand(
            displayName: "Undo Generate Zooms from Gestures",
            keyframesToRemove: generated,
            keyframesToInsert: previousManualKeyframes
        )
    }
}

// MARK: - SetLayoutPreset (Phase 3a)

/// Replaces `Project.layout` wholesale with a new `LayoutPreset`. The
/// Inspector applies one of these per user interaction with the layout
/// picker / cam shape picker / background picker. Because LayoutPreset is
/// small and Equatable, replacing the whole struct is simpler than threading
/// one command per field — the undo stack still folds at the right
/// granularity in practice (each focus-loss / picker click = one command).
public struct SetLayoutPresetCommand: EditCommand {
    public let displayName = "Change Layout"
    public let newLayout: LayoutPreset

    public init(newLayout: LayoutPreset) {
        self.newLayout = newLayout
    }

    @discardableResult
    public func apply(to project: inout Project) throws -> any EditCommand {
        let previous = project.layout
        project.layout = newLayout
        return SetLayoutPresetCommand(newLayout: previous)
    }
}

// MARK: - SetCursorSettings (Phase 3c)

/// Replaces `Project.cursorSettings` wholesale with a new `CursorSettings`.
/// Mirrors `SetLayoutPresetCommand`: the LayoutInspector applies one per
/// user interaction with the cursor-size slider (committed on
/// `onEditingChanged: false`, not per slider-drag tick, so the undo stack
/// gets one entry per release rather than dozens).
public struct SetCursorSettingsCommand: EditCommand {
    public let displayName = "Change Cursor"
    public let newSettings: CursorSettings

    public init(newSettings: CursorSettings) {
        self.newSettings = newSettings
    }

    @discardableResult
    public func apply(to project: inout Project) throws -> any EditCommand {
        let previous = project.cursorSettings
        project.cursorSettings = newSettings
        return SetCursorSettingsCommand(newSettings: previous)
    }
}

// MARK: - RationalTime arithmetic helpers (editor-internal)

extension RationalTime {
    fileprivate func adding(_ other: RationalTime) -> RationalTime {
        precondition(timescale == other.timescale,
                     "Mixed timescales in editor arithmetic — convert first")
        return RationalTime(value: value + other.value, timescale: timescale)
    }

    fileprivate func subtracting(_ other: RationalTime) -> RationalTime {
        precondition(timescale == other.timescale,
                     "Mixed timescales in editor arithmetic — convert first")
        return RationalTime(value: value - other.value, timescale: timescale)
    }

    fileprivate func negated() -> RationalTime {
        RationalTime(value: -value, timescale: timescale)
    }
}
