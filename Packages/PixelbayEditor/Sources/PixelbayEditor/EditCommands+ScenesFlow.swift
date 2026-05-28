import Foundation
import PixelbayCore

// Slice A.2 — scenes-flow follow-ups. Lives in its own file (not appended
// to `EditCommands.swift`) so the parallel `feature/grouped-timeline` branch
// can grow its own command surface without merge conflicts on this file.
//
// Commands:
//  • `SetClipExtraCommand` — applies a key/value pair (or removes a key) on
//    a single clip's `extras` dict. The scenes window's "History" section
//    uses this to write `clip.extras["sceneDescription"]` from edits made
//    on history rows.
//  • `MoveClipsByGroupCommand` — repositions every clip carrying the same
//    `extras["sceneID"]` so a visual reorder of scenes in the history
//    section maps to a coherent multi-track timeline reorder. All affected
//    clips shift by the same delta; sub-clip timing within each scene is
//    preserved.

// MARK: - SetClipExtraCommand

/// Sets (or removes) a single key on a Clip's `extras` dictionary. The
/// scenes-history UI uses this to commit description edits on read-only
/// history rows: each scene's clips share the same `sceneID`, so the UI
/// dispatches one `SetClipExtraCommand` per matching clip via a batch
/// (Phase 2 doesn't bundle multiple commands into one undo entry; the
/// history-row UI submits sequentially and accepts one undo per clip).
///
/// `value: nil` removes the key. Inverse always restores the prior value
/// (which may itself be nil → the inverse will be a remove).
public struct SetClipExtraCommand: EditCommand {
    public let displayName = "Edit Scene Metadata"
    public let clipID: ClipID
    public let key: String
    public let value: JSONValue?

    public init(clipID: ClipID, key: String, value: JSONValue?) {
        self.clipID = clipID
        self.key = key
        self.value = value
    }

    @discardableResult
    public func apply(to project: inout Project) throws -> any EditCommand {
        var previous: JSONValue?
        try project.mutateClip(clipID) { clip in
            previous = clip.extras[key]
            if let value {
                clip.extras[key] = value
            } else {
                clip.extras.removeValue(forKey: key)
            }
        }
        return SetClipExtraCommand(clipID: clipID, key: key, value: previous)
    }
}

// MARK: - MoveClipsByGroupCommand

/// Reorders all clips that carry the same `extras["sceneID"]` so the
/// scene that currently sits at `currentSceneIndex` (in display order of
/// distinct sceneIDs, sorted by each group's earliest timelineRange.start)
/// moves to `targetSceneIndex`. Inter-scene gaps are preserved; intra-scene
/// timing is preserved (every clip in a moving scene shifts by the same
/// delta).
///
/// Inverse swaps the two indices so a single ⌘Z restores the original
/// order. Idempotent when `currentSceneIndex == targetSceneIndex`.
///
/// Throws `EditError.invalidTimelineRange` when either index is out of
/// range relative to the discovered sceneID groups.
public struct MoveClipsByGroupCommand: EditCommand {
    public let displayName = "Reorder Scene"
    public let sceneID: String
    public let targetSceneIndex: Int

    public init(sceneID: String, targetSceneIndex: Int) {
        self.sceneID = sceneID
        self.targetSceneIndex = targetSceneIndex
    }

    @discardableResult
    public func apply(to project: inout Project) throws -> any EditCommand {
        // Build the ordered list of distinct sceneID groups by walking every
        // clip in every track, grouping by `extras["sceneID"]`, sorting the
        // groups by each group's earliest timelineRange.start.
        let groups = Self.discoverSceneGroups(in: project)
        guard !groups.isEmpty else {
            throw EditError.invalidTimelineRange(
                reason: "no scene-tagged clips to reorder"
            )
        }
        guard let currentIndex = groups.firstIndex(where: { $0.sceneID == sceneID }) else {
            throw EditError.invalidTimelineRange(
                reason: "sceneID \(sceneID) not found among scene-tagged clips"
            )
        }
        let clampedTarget = max(0, min(groups.count - 1, targetSceneIndex))
        if clampedTarget == currentIndex {
            // No-op (and no need to register an inverse). Return a same-index
            // command so the history layer still observes a round-trippable
            // pair without further special-casing.
            return MoveClipsByGroupCommand(
                sceneID: sceneID,
                targetSceneIndex: currentIndex
            )
        }

        // Build the new group ordering by removing the moving group and
        // re-inserting at the clamped target index.
        var reordered = groups
        let moving = reordered.remove(at: currentIndex)
        reordered.insert(moving, at: clampedTarget)

        // Recompute each group's new start (preserving inter-group gaps
        // exactly as they appeared in `groups`, in the new order). The
        // delta = newGroupStart - oldGroupStart is applied to every clip
        // in the group across all tracks.
        let oldStarts = groups.map(\.startSeconds)
        var newStarts: [Double] = []
        newStarts.reserveCapacity(reordered.count)
        var cursor = oldStarts.first ?? 0
        for (i, group) in reordered.enumerated() {
            newStarts.append(cursor)
            // Advance the cursor by this group's duration + the original
            // gap that followed the group sitting at this slot in the
            // pre-move ordering. Last slot: no following-gap to add.
            cursor += group.durationSeconds
            if i < reordered.count - 1 {
                // Pre-move gap between slot i and slot i+1 (in OLD order).
                let oldEnd = oldStarts[i] + groups[i].durationSeconds
                let oldFollowingStart = oldStarts[i + 1]
                let originalGap = max(0, oldFollowingStart - oldEnd)
                cursor += originalGap
            }
        }

        // Apply per-group deltas to each affected clip's timelineRange.start.
        for (i, group) in reordered.enumerated() {
            let delta = newStarts[i] - group.startSeconds
            if abs(delta) < 1e-9 { continue }
            for clipID in group.clipIDs {
                try project.mutateClip(clipID) { clip in
                    let currentStartSec = clip.timelineRange.start.seconds
                    let scale = clip.timelineRange.start.timescale
                    let newStartSec = currentStartSec + delta
                    let newStart = RationalTime(
                        value: Int64((newStartSec * Double(scale)).rounded()),
                        timescale: scale
                    )
                    clip.timelineRange = TimeRange(
                        start: newStart,
                        duration: clip.timelineRange.duration
                    )
                }
            }
            // Each track may have moved a clip out of order; re-sort the
            // tracks the moved clips landed on so insertClipMaintainingOrder
            // invariants survive subsequent inserts.
        }
        // Resort every track that contained any moved clip so subsequent
        // `insertClipMaintainingOrder` callers still see ascending order by
        // timelineRange.start.
        let touchedTrackIndices = Self.tracksContaining(
            groups: reordered, in: project
        )
        for trackIdx in touchedTrackIndices {
            project.tracks[trackIdx].clips.sort {
                $0.timelineRange.start.value < $1.timelineRange.start.value
            }
        }

        return MoveClipsByGroupCommand(
            sceneID: sceneID,
            targetSceneIndex: currentIndex
        )
    }

    // MARK: Group discovery

    fileprivate struct SceneGroup {
        let sceneID: String
        let clipIDs: [ClipID]
        let startSeconds: Double
        let durationSeconds: Double
    }

    fileprivate static func discoverSceneGroups(in project: Project) -> [SceneGroup] {
        var byID: [String: (clipIDs: [ClipID], start: Double, end: Double)] = [:]
        for track in project.tracks {
            for clip in track.clips {
                guard case .string(let id)? = clip.extras["sceneID"] else { continue }
                let startSec = clip.timelineRange.start.seconds
                let endSec = startSec + clip.timelineRange.duration.seconds
                if var existing = byID[id] {
                    existing.clipIDs.append(clip.id)
                    existing.start = min(existing.start, startSec)
                    existing.end = max(existing.end, endSec)
                    byID[id] = existing
                } else {
                    byID[id] = (clipIDs: [clip.id], start: startSec, end: endSec)
                }
            }
        }
        return byID
            .map { (id, payload) in
                SceneGroup(
                    sceneID: id,
                    clipIDs: payload.clipIDs,
                    startSeconds: payload.start,
                    durationSeconds: max(0, payload.end - payload.start)
                )
            }
            .sorted { $0.startSeconds < $1.startSeconds }
    }

    fileprivate static func tracksContaining(
        groups: [SceneGroup],
        in project: Project
    ) -> Set<Int> {
        var touched: Set<Int> = []
        let allClipIDs = Set(groups.flatMap(\.clipIDs))
        for (trackIdx, track) in project.tracks.enumerated() {
            if track.clips.contains(where: { allClipIDs.contains($0.id) }) {
                touched.insert(trackIdx)
            }
        }
        return touched
    }
}

// MARK: - _AppendAssetsCommand

/// Internal helper for the editor-side append-merge path (Slice A.2). Adds
/// a batch of MediaAssets to `project.assets` without an
/// `AddAssetCommand` in the public vocabulary (v0.1 didn't expose one
/// because assets were write-once at recording time). Skips assets whose
/// IDs already live in `project.assets` so re-applying after undo is safe.
/// Inverse removes the same IDs.
public struct _AppendAssetsCommand: EditCommand {
    public let displayName = "Attach Scene Recordings"
    public let assets: [MediaAsset]

    public init(assets: [MediaAsset]) {
        self.assets = assets
    }

    @discardableResult
    public func apply(to project: inout Project) throws -> any EditCommand {
        var added: [MediaAssetID] = []
        let existing = Set(project.assets.map(\.id))
        for asset in assets where !existing.contains(asset.id) {
            project.assets.append(asset)
            added.append(asset.id)
        }
        return _DetachAssetsCommand(assetIDs: added)
    }
}

/// Inverse of `_AppendAssetsCommand`. Removes the named asset IDs from
/// `project.assets`. Captures the removed assets so its own inverse can
/// reattach them on redo.
struct _DetachAssetsCommand: EditCommand {
    let displayName = "Detach Scene Recordings"
    let assetIDs: [MediaAssetID]

    @discardableResult
    func apply(to project: inout Project) throws -> any EditCommand {
        let idSet = Set(assetIDs)
        let removed = project.assets.filter { idSet.contains($0.id) }
        project.assets.removeAll { idSet.contains($0.id) }
        return _AppendAssetsCommand(assets: removed)
    }
}

// MARK: - ScenesMerger.mergeAppending

extension ScenesMerger {

    /// Variant of `merge(into:)` that appends new scenes to an editor's
    /// existing project tracks instead of starting at `runningOffset = 0`.
    /// The first scene lands at `project.timelineEndSeconds` (the maximum
    /// timelineRange.end across every clip on every non-effects track).
    /// Otherwise behaves identically to `merge(into:)` — same clamp-to-
    /// canonical-duration rule, same extras stamping, same scenesSession
    /// clearing on completion.
    ///
    /// Used by the editor's "Scenes" toolbar button (Slice A.2): the user
    /// records new scenes in the scenes window, clicks Merge, and the new
    /// clips append to the editor's existing timeline rather than creating
    /// a fresh project window.
    @discardableResult
    public static func mergeAppending(into project: inout Project) throws -> Int {
        guard let session = project.scenesSession else {
            throw MergeError.noScenesSession
        }
        // Compute the editor's current timeline tail. Skip effects + overlay
        // tracks (they don't contribute clip endpoints in the canonical
        // sense). If the project is fresh (no clips), fall through to the
        // baseline behaviour at offset 0.
        var existingTailSeconds: Double = 0
        for track in project.tracks {
            switch track.kind {
            case .effects, .overlay:
                continue
            default:
                break
            }
            for clip in track.clips {
                let endSec = clip.timelineRange.start.seconds + clip.timelineRange.duration.seconds
                if endSec > existingTailSeconds {
                    existingTailSeconds = endSec
                }
            }
        }

        var mergedSceneCount = 0
        var runningOffsetSeconds: Double = existingTailSeconds
        // Reuse-track lookup keyed by TrackKind. Seed with the editor's
        // existing tracks so the new scene clips land on the same screen /
        // webcam / mic / sysAudio lanes the user already has. Missing kinds
        // are created lazily as scenes contribute them — the "Add the new
        // track" source-mismatch policy from the plan (a user recording with
        // webcam now even though the editor's project didn't have one yet
        // grows a webcam track for the new clip).
        var trackIndexByKind: [TrackKind: Int] = [:]
        for (idx, track) in project.tracks.enumerated() where trackIndexByKind[track.kind] == nil {
            trackIndexByKind[track.kind] = idx
        }

        let assetByID: [MediaAssetID: MediaAsset] = Dictionary(
            uniqueKeysWithValues: project.assets.map { ($0.id, $0) }
        )

        for scene in session.scenes {
            guard let take = scene.activeTake else { continue }
            if take.assetIDs.isEmpty {
                throw MergeError.takeHasNoAssets(scene.id)
            }
            var takeAssets: [MediaAsset] = []
            takeAssets.reserveCapacity(take.assetIDs.count)
            for assetID in take.assetIDs {
                guard let asset = assetByID[assetID] else {
                    throw MergeError.assetMissing(assetID)
                }
                takeAssets.append(asset)
            }

            let screenAsset = takeAssets.first { ScenesMerger.trackKind(for: $0.kind) == .screen }
            let sceneDurationSeconds = screenAsset?.nativeDuration.seconds
                ?? takeAssets.map { $0.nativeDuration.seconds }.max()
                ?? 0
            let timelineStart = RationalTime.seconds(runningOffsetSeconds)

            for asset in takeAssets {
                guard let kind = ScenesMerger.trackKind(for: asset.kind) else { continue }

                let trackIdx: Int
                if let existing = trackIndexByKind[kind] {
                    trackIdx = existing
                } else {
                    let newTrack = Track(
                        kind: kind,
                        name: ScenesMerger.defaultTrackName(for: kind)
                    )
                    project.tracks.append(newTrack)
                    trackIdx = project.tracks.count - 1
                    trackIndexByKind[kind] = trackIdx
                }

                var clipExtras: [String: JSONValue] = [
                    "sceneID": .string(scene.id.rawValue)
                ]
                if !scene.description.isEmpty {
                    clipExtras["sceneDescription"] = .string(scene.description)
                }

                // Same clamp-to-canonical logic as `merge(into:)`. For
                // sources longer than the scene's canonical duration (cam /
                // mic with pre-roll), take the tail; for shorter sources,
                // use the whole thing and let the compositor pad the tail.
                let assetSeconds = asset.nativeDuration.seconds
                let clampedSeconds = min(assetSeconds, sceneDurationSeconds)
                let sourceStartSeconds = max(0, assetSeconds - clampedSeconds)
                let sourceStart = RationalTime.seconds(sourceStartSeconds)
                let clipDuration = RationalTime.seconds(clampedSeconds)

                let clip = Clip(
                    assetID: asset.id,
                    sourceRange: TimeRange(
                        start: sourceStart,
                        duration: clipDuration
                    ),
                    timelineRange: TimeRange(
                        start: timelineStart,
                        duration: clipDuration
                    ),
                    extras: clipExtras
                )
                project.tracks[trackIdx].insertClipMaintainingOrder(clip)
            }

            runningOffsetSeconds += sceneDurationSeconds
            mergedSceneCount += 1
        }

        project.scenesSession = nil
        return mergedSceneCount
    }
}
