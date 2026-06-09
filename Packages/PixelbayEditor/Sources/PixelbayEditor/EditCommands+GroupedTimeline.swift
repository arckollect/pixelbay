import Foundation
import PixelbayCore

// Branch B (Grouped Timeline) — commands live in this dedicated file
// instead of `EditCommands.swift` so the merge surface against the
// concurrent `feature/scenes-flow` branch (Branch A) stays minimal.
// Branch A is doing the same with its own `EditCommands+ScenesFlow.swift`.
//
// Slice B.4 ships the lane-collapse toggles (single + bulk). Slice B.5
// adds the group-variant trim/move/remove commands used when the user
// edits a collapsed lane's primary clip and the change needs to
// propagate to the underlying physical tracks.

// MARK: - SetLaneCollapsed (Slice B.4)

/// Toggles a single grouped lane's collapse state. When `collapsed:
/// false` (expanding), also sets `track.laneBreakout = true` on every
/// member track of the group — the user's "expand permanently
/// decouples these tracks" intent (polish 2026-05-27): once expanded
/// the tracks render as standalone rows and edits don't propagate.
/// Inverse restores the previous collapse value AND the previous
/// breakout flags so undo brings back the exact prior state.
public struct SetLaneCollapsedCommand: EditCommand {
    public let displayName = "Toggle Lane"
    public let groupID: LaneGroupID
    public let collapsed: Bool

    public init(groupID: LaneGroupID, collapsed: Bool) {
        self.groupID = groupID
        self.collapsed = collapsed
    }

    @discardableResult
    public func apply(to project: inout Project) throws -> any EditCommand {
        let previousCollapse = project.timelineLaneCollapse[groupID]
        // Capture the previous breakout state for every track that
        // belongs to this group by kind (membership is TrackKind-driven
        // even if some are currently broken out).
        var previousBreakouts: [TrackID: Bool] = [:]
        for track in project.tracks where track.kind.laneGroup == groupID {
            previousBreakouts[track.id] = track.laneBreakout
        }

        var map = project.timelineLaneCollapse
        map[groupID] = collapsed
        project.timelineLaneCollapse = map

        // Expand = break out: every member track becomes standalone.
        // Collapse = re-group: clear the breakout flag so any standalone
        // members rejoin the grouped lane. (No-op for already-correct
        // flags.)
        let targetBreakout = !collapsed
        for idx in project.tracks.indices where project.tracks[idx].kind.laneGroup == groupID {
            if project.tracks[idx].laneBreakout != targetBreakout {
                project.tracks[idx].laneBreakout = targetBreakout
            }
        }

        return _RestoreLaneCollapsedCommand(
            groupID: groupID,
            previousCollapse: previousCollapse,
            previousBreakouts: previousBreakouts
        )
    }
}

/// Internal inverse for SetLaneCollapsedCommand. Restores either the
/// previous explicit value OR removes the entry entirely so the
/// smart-default seed re-applies on next read. Also restores every
/// member track's `laneBreakout` flag to its pre-apply value. Not
/// exposed as a user-facing command because the regular toggle command
/// always sets an explicit value.
struct _RestoreLaneCollapsedCommand: EditCommand {
    let displayName = "Restore Lane"
    let groupID: LaneGroupID
    let previousCollapse: Bool?
    let previousBreakouts: [TrackID: Bool]

    @discardableResult
    func apply(to project: inout Project) throws -> any EditCommand {
        let currentCollapseBeforeRestore = project.timelineLaneCollapse[groupID]
        var currentBreakoutsBeforeRestore: [TrackID: Bool] = [:]
        for track in project.tracks where track.kind.laneGroup == groupID {
            currentBreakoutsBeforeRestore[track.id] = track.laneBreakout
        }

        var map = project.timelineLaneCollapse
        if let previous = previousCollapse {
            map[groupID] = previous
        } else {
            map.removeValue(forKey: groupID)
        }
        project.timelineLaneCollapse = map

        for idx in project.tracks.indices {
            let trackID = project.tracks[idx].id
            if let prior = previousBreakouts[trackID],
               project.tracks[idx].laneBreakout != prior {
                project.tracks[idx].laneBreakout = prior
            }
        }

        return _RestoreLaneCollapsedCommand(
            groupID: groupID,
            previousCollapse: currentCollapseBeforeRestore,
            previousBreakouts: currentBreakoutsBeforeRestore
        )
    }
}

// MARK: - SetAllLanesCollapsed (Slice B.4)

/// Bulk toggle every lane group plus the smart-default seed. Used by
/// the editor toolbar's "Expand/Collapse all" button. Stores the full
/// pre-state map, default seed, AND every track's previous laneBreakout
/// flag so the inverse restores exactly.
///
/// "Collapse all" (collapsed=true) clears every track's laneBreakout
/// flag so previously broken-out tracks rejoin their group. "Expand
/// all" (collapsed=false) sets laneBreakout=true on every groupable
/// track so they all render as standalone rows. Matches the user
/// intent (polish 2026-05-27): expand = decouple, collapse = regroup.
public struct SetAllLanesCollapsedCommand: EditCommand {
    public let displayName = "Toggle All Lanes"
    public let collapsed: Bool

    public init(collapsed: Bool) {
        self.collapsed = collapsed
    }

    @discardableResult
    public func apply(to project: inout Project) throws -> any EditCommand {
        let previousMap = project.timelineLaneCollapse
        let previousDefault = project.timelineLaneCollapseDefault
        var previousBreakouts: [TrackID: Bool] = [:]
        for track in project.tracks where track.kind.laneGroup != nil {
            previousBreakouts[track.id] = track.laneBreakout
        }

        var newMap: [LaneGroupID: Bool] = [:]
        for group in LaneGroupID.allCases {
            newMap[group] = collapsed
        }
        project.timelineLaneCollapse = newMap
        project.timelineLaneCollapseDefault = collapsed

        let targetBreakout = !collapsed
        for idx in project.tracks.indices where project.tracks[idx].kind.laneGroup != nil {
            if project.tracks[idx].laneBreakout != targetBreakout {
                project.tracks[idx].laneBreakout = targetBreakout
            }
        }

        return _RestoreAllLanesCollapsedCommand(
            previousMap: previousMap,
            previousDefault: previousDefault,
            previousBreakouts: previousBreakouts
        )
    }
}

/// Internal inverse for SetAllLanesCollapsedCommand. Restores the full
/// pre-state (including any custom per-lane values, the smart-default
/// seed, and every track's laneBreakout flag) so the user's prior
/// configuration comes back exactly.
struct _RestoreAllLanesCollapsedCommand: EditCommand {
    let displayName = "Restore All Lanes"
    let previousMap: [LaneGroupID: Bool]
    let previousDefault: Bool
    let previousBreakouts: [TrackID: Bool]

    @discardableResult
    func apply(to project: inout Project) throws -> any EditCommand {
        let currentMap = project.timelineLaneCollapse
        let currentDefault = project.timelineLaneCollapseDefault
        var currentBreakouts: [TrackID: Bool] = [:]
        for track in project.tracks where track.kind.laneGroup != nil {
            currentBreakouts[track.id] = track.laneBreakout
        }

        project.timelineLaneCollapse = previousMap
        project.timelineLaneCollapseDefault = previousDefault
        for idx in project.tracks.indices {
            let trackID = project.tracks[idx].id
            if let prior = previousBreakouts[trackID],
               project.tracks[idx].laneBreakout != prior {
                project.tracks[idx].laneBreakout = prior
            }
        }

        return _RestoreAllLanesCollapsedCommand(
            previousMap: currentMap,
            previousDefault: currentDefault,
            previousBreakouts: currentBreakouts
        )
    }
}

// MARK: - Group-variant trim/move/remove commands (Slice B.5)
//
// When a lane is collapsed and the user trims / moves / removes the
// primary clip, the edit must propagate to every overlapping clip on
// the lane's underlying physical tracks. These commands take a
// `[ClipID]` instead of one ID and apply the same delta / new-start /
// removal to every member atomically (single undo entry per group
// edit).
//
// The TimelineNSView mouseUp handler decides single vs. group by
// inspecting the project's lane-collapse state at the affected clip's
// track, then asks `Project.clipsOnCollapsedLaneOverlapping(_:)` for
// the full member set. That helper lives below as a Project extension
// so tests can drive it without touching the NSView.

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
    /// For Slice B.5: returns every clip on the same collapsed grouped
    /// lane as `leadClipID` whose timeline range intersects the lead
    /// clip's range. Used by `TimelineNSView.mouseUp` to decide which
    /// clips a collapsed-lane drag should propagate to. Returns just
    /// `[leadClipID]` if the lead clip's lane is NOT collapsed (no
    /// propagation needed — the single-clip command applies as
    /// before).
    ///
    /// The lead clip itself is always included as the first element.
    /// `effects` tracks never participate in lane grouping so they're
    /// excluded regardless.
    func clipsOnCollapsedLaneOverlapping(_ leadClipID: ClipID) -> [ClipID] {
        guard let (leadTrackIdx, leadClipIdx) = locateClip(leadClipID) else {
            return []
        }
        let leadTrack = tracks[leadTrackIdx]
        let leadClip = leadTrack.clips[leadClipIdx]
        // If the lead track is broken out, it's standalone — no
        // propagation. Same return as the expanded-lane case below.
        if leadTrack.laneBreakout { return [leadClipID] }
        guard let group = leadTrack.kind.laneGroup else { return [leadClipID] }
        guard isLaneCollapsed(group) else { return [leadClipID] }

        let leadRange = leadClip.timelineRange
        var result: [ClipID] = [leadClipID]
        for track in tracks where track.id != leadTrack.id {
            guard track.kind.laneGroup == group else { continue }
            // Broken-out group members are independent — don't pull
            // them along when the rest of the lane is collapsed.
            if track.laneBreakout { continue }
            for clip in track.clips where clip.id != leadClipID {
                if clip.timelineRange.overlaps(leadRange) {
                    result.append(clip.id)
                }
            }
        }
        return result
    }
}
