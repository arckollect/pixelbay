import Foundation
import PixelbayCore

// Grouped-timeline commands. The timeline shows one Video row and one
// Audio row (plus Effects); each row's visible band is its primary track
// (screen / microphone). When the user trims / moves / removes that
// primary clip, the edit must propagate to every overlapping clip on the
// row's other physical tracks so screen + webcam (or mic + system audio)
// stay in sync. These commands take a `[ClipID]` instead of one ID and
// apply the same delta / new-start / removal to every member atomically
// (single undo entry per group edit).
//
// The TimelineNSView mouseUp handler asks
// `Project.clipsOnLaneOverlapping(_:)` for the member set, then picks the
// single- or group-variant command by count. That helper lives at the
// bottom of this file as a Project extension so tests can drive it
// without touching the NSView.

// MARK: - Group-variant trim/move/remove commands

/// Group variant of `TrimClipInCommand`. Trims (or expands) the
/// IN-point of every clip in `clipIDs` by `delta`. Per-clip apply
/// preserves the same bounds checks as the single-clip command —
/// if ANY clip would invert its source/timeline range, the WHOLE
/// command throws and the project is restored to the pre-state.
public struct TrimClipsGroupCommand: EditCommand {
    public let displayName = "Trim Clips"
    public let clipIDs: [ClipID]
    public let delta: RationalTime

    public init(clipIDs: [ClipID], delta: RationalTime) {
        self.clipIDs = clipIDs
        self.delta = delta
    }

    @discardableResult
    public func apply(to project: inout Project) throws -> any EditCommand {
        let snapshot = project
        do {
            for clipID in clipIDs {
                _ = try TrimClipInCommand(clipID: clipID, delta: delta).apply(to: &project)
            }
        } catch {
            project = snapshot
            throw error
        }
        // Inverse: same set, negated delta.
        return TrimClipsGroupCommand(
            clipIDs: clipIDs,
            delta: RationalTime(value: -delta.value, timescale: delta.timescale)
        )
    }
}

/// Group variant of `TrimClipOutCommand`. Same all-or-nothing
/// semantics as `TrimClipsGroupCommand` — if any clip's apply
/// fails, the whole project is rolled back.
public struct TrimClipsOutGroupCommand: EditCommand {
    public let displayName = "Trim Clips"
    public let clipIDs: [ClipID]
    public let delta: RationalTime

    public init(clipIDs: [ClipID], delta: RationalTime) {
        self.clipIDs = clipIDs
        self.delta = delta
    }

    @discardableResult
    public func apply(to project: inout Project) throws -> any EditCommand {
        let snapshot = project
        do {
            for clipID in clipIDs {
                _ = try TrimClipOutCommand(clipID: clipID, delta: delta).apply(to: &project)
            }
        } catch {
            project = snapshot
            throw error
        }
        return TrimClipsOutGroupCommand(
            clipIDs: clipIDs,
            delta: RationalTime(value: -delta.value, timescale: delta.timescale)
        )
    }
}

/// Group variant of `MoveClipCommand`. Computes a per-clip delta from
/// the LEAD clip's original timeline start → newTimelineStart, then
/// applies that delta to every other clip in the group so synced
/// clips stay synced. `leadClipID` MUST be in `clipIDs`.
public struct MoveClipsGroupCommand: EditCommand {
    public let displayName = "Move Clips"
    public let clipIDs: [ClipID]
    public let leadClipID: ClipID
    public let newTimelineStart: RationalTime

    public init(clipIDs: [ClipID], leadClipID: ClipID, newTimelineStart: RationalTime) {
        self.clipIDs = clipIDs
        self.leadClipID = leadClipID
        self.newTimelineStart = newTimelineStart
    }

    @discardableResult
    public func apply(to project: inout Project) throws -> any EditCommand {
        guard let leadClip = project.clip(leadClipID) else {
            throw EditError.clipNotFound(leadClipID)
        }
        let leadOriginalStart = leadClip.timelineRange.start
        let deltaSeconds = newTimelineStart.seconds - leadOriginalStart.seconds
        let snapshot = project
        do {
            for clipID in clipIDs {
                guard let clip = project.clip(clipID) else {
                    throw EditError.clipNotFound(clipID)
                }
                let newStartSeconds = clip.timelineRange.start.seconds + deltaSeconds
                let newStart = RationalTime(
                    value: Int64((newStartSeconds * Double(clip.timelineRange.start.timescale)).rounded()),
                    timescale: clip.timelineRange.start.timescale
                )
                _ = try MoveClipCommand(
                    clipID: clipID,
                    newTimelineStart: newStart
                ).apply(to: &project)
            }
        } catch {
            project = snapshot
            throw error
        }
        // Inverse: same set, lead moves back to its original start —
        // the delta-of-delta is symmetric so the other clips return
        // to their original positions too.
        return MoveClipsGroupCommand(
            clipIDs: clipIDs,
            leadClipID: leadClipID,
            newTimelineStart: leadOriginalStart
        )
    }
}

/// Group variant of `RemoveClipCommand`. Captures every removed clip
/// + its owning track so the inverse can reinsert them. Track IDs are
/// resolved lazily on apply because the same group can be applied to
/// projects with different ID maps in testing — the inverse picks up
/// the actual track IDs from the pre-state.
public struct RemoveClipsGroupCommand: EditCommand {
    public let displayName = "Remove Clips"
    public let clipIDs: [ClipID]

    public init(clipIDs: [ClipID]) {
        self.clipIDs = clipIDs
    }

    @discardableResult
    public func apply(to project: inout Project) throws -> any EditCommand {
        var removed: [(trackID: TrackID, clip: Clip)] = []
        for clipID in clipIDs {
            guard let (trackIdx, clipIdx) = project.locateClip(clipID) else {
                // Skip silently — a previous remove in this group may
                // have already taken it (defensive against duplicates
                // in the caller-built clipIDs list).
                continue
            }
            let trackID = project.tracks[trackIdx].id
            let clip = project.tracks[trackIdx].clips.remove(at: clipIdx)
            removed.append((trackID: trackID, clip: clip))
        }
        return _ReinsertClipsGroupCommand(removed: removed)
    }
}

/// Internal inverse for `RemoveClipsGroupCommand`. Inserts every
/// removed clip back onto its original track, in the same maintain-
/// ordering pattern that `InsertClipCommand` uses.
struct _ReinsertClipsGroupCommand: EditCommand {
    let displayName = "Restore Clips"
    let removed: [(trackID: TrackID, clip: Clip)]

    @discardableResult
    func apply(to project: inout Project) throws -> any EditCommand {
        for entry in removed {
            guard let trackIdx = project.locateTrack(entry.trackID) else {
                throw EditError.trackNotFound(entry.trackID)
            }
            project.tracks[trackIdx].insertClipMaintainingOrder(entry.clip)
        }
        return RemoveClipsGroupCommand(clipIDs: removed.map(\.clip.id))
    }
}

// MARK: - Grouped-lane clip resolution helpers

public extension Project {
    /// Returns every clip on the same grouped lane as `leadClipID` whose
    /// timeline range intersects the lead clip's range. Used by
    /// `TimelineNSView.mouseUp` to decide which clips a grouped-row drag
    /// should propagate to. Returns just `[leadClipID]` when the lead
    /// track has no lane group (`.effects`) or nothing overlaps.
    ///
    /// The lead clip itself is always included as the first element.
    func clipsOnLaneOverlapping(_ leadClipID: ClipID) -> [ClipID] {
        guard let (leadTrackIdx, leadClipIdx) = locateClip(leadClipID) else {
            return []
        }
        let leadTrack = tracks[leadTrackIdx]
        let leadClip = leadTrack.clips[leadClipIdx]
        guard let group = leadTrack.kind.laneGroup else { return [leadClipID] }

        let leadRange = leadClip.timelineRange
        var result: [ClipID] = [leadClipID]
        for track in tracks where track.id != leadTrack.id {
            guard track.kind.laneGroup == group else { continue }
            for clip in track.clips where clip.id != leadClipID {
                if clip.timelineRange.overlaps(leadRange) {
                    result.append(clip.id)
                }
            }
        }
        return result
    }
}
