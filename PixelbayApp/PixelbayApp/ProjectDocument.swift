import Foundation
import OSLog
import Observation
import PixelbayCore
import PixelbayEditor

private let log = Logger(subsystem: "com.pixelbay.PixelbayApp", category: "ProjectDocument")

// MainActor-bound document object that wires the Editor model into SwiftUI.
//
// Owns:
//   • the EditHistory actor (which owns the Project + undo/redo stacks)
//   • a mirror of the Project on the main actor (so SwiftUI binds without
//     async hops; refreshed on every command apply / undo / redo / load)
//   • the bundle URL (for save)
//   • a "dirty" flag (true between mutations and the next save)
//
// Phase 2 v0.1's Inspector + Save / Undo / Redo work against this. The
// timeline UI in PixelbayTimelineUI will bind to the same shape — its
// drag-handlers post EditCommands through `apply(_:)`.

@MainActor
@Observable
final class ProjectDocument {
    enum Status: Equatable {
        case idle
        case loading
        case ready
        case saving
        case failed(message: String)
    }

    private(set) var status: Status = .idle
    private(set) var project: Project
    private(set) var canUndo: Bool = false
    private(set) var canRedo: Bool = false
    private(set) var undoActionName: String?
    private(set) var redoActionName: String?
    private(set) var isDirty: Bool = false
    /// Monotonic counter incremented on every apply / undo / redo. Used by
    /// ProjectView to key its preview-rebuild task — each committed edit
    /// reloads the AVMutableComposition so playback reflects trims /
    /// splits / volume changes immediately. Save does NOT bump this:
    /// content is unchanged, just persisted.
    private(set) var revision: Int = 0

    let bundleURL: URL
    private let history: EditHistory
    private let store: ProjectBundleStore

    init(bundleURL: URL, project: Project, store: ProjectBundleStore = ProjectBundleStore()) {
        self.bundleURL = bundleURL
        self.project = project
        self.history = EditHistory(project: project)
        self.store = store
        self.status = .ready
    }

    /// Apply a command via the underlying EditHistory actor and refresh
    /// the main-actor mirror. Errors surface as Status.failed(message:);
    /// callers are expected to surface them in UI.
    func apply(_ command: any EditCommand) async {
        do {
            try await history.apply(command)
            await refreshFromHistory()
            isDirty = true
            revision &+= 1
        } catch {
            log.error("apply \(command.displayName, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            status = .failed(message: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }

    func undo() async {
        do {
            try await history.undo()
            await refreshFromHistory()
            isDirty = true
            revision &+= 1
        } catch {
            log.error("undo failed: \(String(describing: error), privacy: .public)")
            status = .failed(message: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }

    func redo() async {
        do {
            try await history.redo()
            await refreshFromHistory()
            isDirty = true
            revision &+= 1
        } catch {
            log.error("redo failed: \(String(describing: error), privacy: .public)")
            status = .failed(message: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }

    /// Atomic save back to project.json. Updates the in-memory project's
    /// `modifiedAt` first so the on-disk file reflects the save time.
    func save() async {
        guard !project.tracks.isEmpty || !project.assets.isEmpty || isDirty else { return }
        status = .saving
        var snapshot = project
        snapshot.modifiedAt = Date()
        let bundle = ProjectBundle(url: bundleURL)
        do {
            try store.writeProject(snapshot, to: bundle)
            await history.replace(project: snapshot)
            await refreshFromHistory()
            isDirty = false
            status = .ready
            log.info("saved project at \(self.bundleURL.path, privacy: .public)")
        } catch {
            log.error("save failed: \(String(describing: error), privacy: .public)")
            status = .failed(message: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }

    func acknowledgeError() {
        if case .failed = status {
            status = .ready
        }
    }

    // MARK: - Slice A.3 — append a single-shot recording to the timeline tail

    /// Appends a `RecordingService.Result` to this document's timeline. The
    /// recording was driven with `appendTracks: false` against THIS bundle
    /// (so the writer pushed assets into `project.assets` but didn't create
    /// tracks). For each appended asset we:
    ///   1. Compute the timeline tail (max `timelineRange.end` across
    ///      non-effects/non-overlay tracks).
    ///   2. Map the asset's CaptureSourceKind to a TrackKind (reusing
    ///      `ScenesMerger.trackKind(for:)`).
    ///   3. Resolve or create the matching Track via `AddTrackCommand`.
    ///   4. Build a Clip with sourceRange = whole-asset, timelineRange =
    ///      [tailSeconds, tailSeconds + nativeDuration]; insert via
    ///      `InsertClipCommand`. No `sceneID` extras — these aren't scenes.
    /// All operations go through `apply(_:)` so the editor's undo / redo
    /// stack covers the entire append.
    ///
    /// Reloads the project from disk first so we see the assets the
    /// RecordingService just persisted (`project.assets` mutations bypass
    /// the EditHistory pipeline because they're writer side effects, not
    /// user edits). Then dispatches a single `_AppendAssetsCommand` for the
    /// new assets so they're discoverable under undo too.
    func appendRecordingToTimeline(result: RecordingService.Result) async {
        let store = ProjectBundleStore()
        let bundle = ProjectBundle(url: bundleURL)
        let diskProject: Project
        do {
            diskProject = try store.loadProject(from: bundle)
        } catch {
            log.error("appendRecording: loadProject failed: \(String(describing: error), privacy: .public)")
            status = .failed(message: error.localizedDescription)
            return
        }

        let appendedAssets = diskProject.assets.filter { asset in
            result.assetIDs.contains(asset.id) && !project.assets.contains(where: { $0.id == asset.id })
        }
        if !appendedAssets.isEmpty {
            await apply(_AppendAssetsCommand(assets: appendedAssets))
        }

        // Compute timeline tail across non-effects/non-overlay tracks.
        var tailSeconds: Double = 0
        for track in project.tracks {
            switch track.kind {
            case .effects, .overlay: continue
            default: break
            }
            for clip in track.clips {
                let endSec = clip.timelineRange.start.seconds + clip.timelineRange.duration.seconds
                if endSec > tailSeconds { tailSeconds = endSec }
            }
        }

        // Determine the canonical recording length for this append. Use the
        // screen asset's nativeDuration when present (the user-visible
        // length of the recording); fall back to the longest assertion in
        // the assets list (rare — audio-only or test fixtures).
        let assetsForThisRecording = appendedAssets
        let screenAsset = assetsForThisRecording.first {
            ScenesMerger.trackKind(for: $0.kind) == .screen
        }
        let canonicalSeconds = screenAsset?.nativeDuration.seconds
            ?? assetsForThisRecording.map { $0.nativeDuration.seconds }.max()
            ?? 0
        guard canonicalSeconds > 0 else {
            log.info("appendRecording: zero canonical duration; nothing to insert")
            return
        }

        let timelineStart = RationalTime.seconds(tailSeconds)

        // Index existing tracks by kind so we reuse the user's existing
        // screen / cam / mic / sysAudio lanes instead of duplicating.
        var trackByKind: [TrackKind: TrackID] = [:]
        for track in project.tracks where trackByKind[track.kind] == nil {
            trackByKind[track.kind] = track.id
        }

        for asset in assetsForThisRecording {
            guard let kind = ScenesMerger.trackKind(for: asset.kind) else { continue }
            // Resolve / create the destination track.
            let trackID: TrackID
            if let existing = trackByKind[kind] {
                trackID = existing
            } else {
                let newTrack = Track(
                    kind: kind,
                    name: ScenesMerger.defaultTrackName(for: kind)
                )
                trackID = newTrack.id
                trackByKind[kind] = trackID
                await apply(AddTrackCommand(track: newTrack))
            }

            // Clamp to canonical seconds (mirrors `ScenesMerger.merge` — cam /
            // mic / sysAudio start before SCStream so their natural duration
            // can exceed the screen's; take the tail). For sources shorter
            // than canonical, use the whole thing.
            let assetSeconds = asset.nativeDuration.seconds
            let clampedSeconds = min(assetSeconds, canonicalSeconds)
            let sourceStartSeconds = max(0, assetSeconds - clampedSeconds)
            let clip = Clip(
                assetID: asset.id,
                sourceRange: TimeRange(
                    start: RationalTime.seconds(sourceStartSeconds),
                    duration: RationalTime.seconds(clampedSeconds)
                ),
                timelineRange: TimeRange(
                    start: timelineStart,
                    duration: RationalTime.seconds(clampedSeconds)
                )
            )
            await apply(InsertClipCommand(trackID: trackID, clip: clip))
        }
    }

    // MARK: - Phase 5 — cleanup unused takes

    /// True iff this project would benefit from a Clean-up-unused-takes
    /// pass. Surfaces to the menu command for visibility gating. Returns
    /// true when either (a) the project still carries a scenesSession
    /// (pre-merge state with discarded takes) or (b) project.assets
    /// contains any asset that isn't referenced by any Clip on any
    /// non-effects/non-overlay track (post-merge orphan).
    var hasOrphanedAssetsOrTakes: Bool {
        if let session = project.scenesSession {
            for scene in session.scenes where scene.takes.count > 1 {
                // More than one take means at least one is inactive →
                // eligible to drop.
                return true
            }
            // Empty scenes / no extra takes — fall through to the orphan
            // check below; nothing to gain unless project.assets has
            // unreferenced entries.
        }
        let referenced = Set(project.tracks.flatMap { $0.clips }.map { $0.assetID })
        let activeFromSession: Set<MediaAssetID> = {
            guard let session = project.scenesSession else { return [] }
            var ids: Set<MediaAssetID> = []
            for scene in session.scenes {
                if let take = scene.activeTake {
                    ids.formUnion(take.assetIDs)
                }
            }
            return ids
        }()
        for asset in project.assets {
            if !referenced.contains(asset.id) && !activeFromSession.contains(asset.id) {
                return true
            }
        }
        return false
    }

    /// Runs `ScenesBundleStore.cleanupUnusedTakes` on the project, writes
    /// back to disk, refreshes the in-memory mirror. No-op when there's
    /// nothing to clean. Bumps `revision` so any open preview rebuild
    /// picks up the asset-removal (rare — clip references are preserved
    /// — but the asset list is part of the composition build's input).
    @discardableResult
    func cleanupUnusedTakes() async -> ScenesBundleStore.CleanupReport {
        var snapshot = project
        do {
            let report = try ScenesBundleStore.cleanupUnusedTakes(
                in: &snapshot,
                bundleURL: bundleURL
            )
            guard !report.removedAssetIDs.isEmpty || !report.removedFilePaths.isEmpty else {
                return report
            }
            let bundle = ProjectBundle(url: bundleURL)
            snapshot.modifiedAt = Date()
            try store.writeProject(snapshot, to: bundle)
            await history.replace(project: snapshot)
            await refreshFromHistory()
            revision &+= 1
            isDirty = false
            log.info("cleanup removed assetCount=\(report.removedAssetIDs.count) fileCount=\(report.removedFilePaths.count)")
            return report
        } catch {
            log.error("cleanup failed: \(String(describing: error), privacy: .public)")
            status = .failed(message: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            return ScenesBundleStore.CleanupReport()
        }
    }

    /// Open a project bundle from disk into a fresh ProjectDocument. Returns
    /// nil with logging if the bundle is missing project.json or fails to
    /// decode — the caller (App.openProject) surfaces the error in UI.
    ///
    /// Auto-heals projects that have MediaAssets but no Tracks. Pre-fix
    /// recordings (RecordingService versions before 2026-05-02) only wrote
    /// MediaAsset records, never the Tracks/Clips that PreviewCompositionBuilder
    /// iterates — opening such a project would surface "Project has no screen
    /// recording asset to preview" with no editable surface. The synthesized
    /// tracks aren't marked dirty (no implicit "Save (modified)" badge); they
    /// persist only if the user makes some other edit and saves.
    static func open(bundleURL: URL, store: ProjectBundleStore = ProjectBundleStore()) async throws -> ProjectDocument {
        let bundle = ProjectBundle(url: bundleURL)
        var project = try store.loadProject(from: bundle)
        if project.tracks.isEmpty, !project.assets.isEmpty {
            synthesizeTracksFromAssets(into: &project)
            log.info("auto-healed missing tracks for \(bundleURL.path, privacy: .public) — synthesized \(project.tracks.count) track(s)")
        }
        // Auto-heal for pre-2026-05-27 recordings whose non-screen tracks
        // were stamped with `timelineRange.duration == nativeDuration`
        // (i.e. cam / mic / sysAudio clips appearing as short stubs even
        // though the user recorded for the full screen duration). Extend
        // every non-screen track's clip to span the longest screen
        // clip's timeline range, leaving `sourceRange` alone — the
        // compositor pads the tail with silence/transparency when
        // sourceRange < timelineRange and `clip.speed == 1.0`.
        if extendShortNonScreenClipsToCanonicalTimeline(into: &project) {
            log.info("auto-healed short non-screen clip timeline ranges at \(bundleURL.path, privacy: .public)")
        }
        // Repair overlapping clips on the same track. An earlier
        // version of `extendShortNonScreenClipsToCanonicalTimeline`
        // stretched every non-screen clip to the canonical screen
        // end without checking for subsequent clips, so scenes-merged
        // projects ended up with scene 1's clip overlapping scene 2's.
        // AVMutableAudioMix rejects overlapping volume ramps and the
        // Metal compositor errors out on missing screen layers when
        // two clips occupy the same timeline range. This pass shrinks
        // any clip whose end exceeds the next clip's start on the
        // same track. Idempotent — no-op when clips are already
        // non-overlapping.
        if shrinkOverlappingClipsOnSameTrack(into: &project) {
            log.info("auto-healed overlapping clips on shared tracks at \(bundleURL.path, privacy: .public)")
        }
        log.info("opened project at \(bundleURL.path, privacy: .public)")
        return ProjectDocument(bundleURL: bundleURL, project: project, store: store)
    }

    /// Walks `project.tracks` and extends every non-screen-track clip's
    /// `timelineRange.duration` to match the longest screen-track clip's
    /// timeline range, when:
    ///   • the clip's existing `timelineRange.duration` is shorter than
    ///     the screen's, AND
    ///   • `clip.speed == 1.0` (so we don't accidentally extend a
    ///     user-trimmed or sped-up clip — those have explicit intent).
    /// `sourceRange` is left untouched; PreviewComposition handles the
    /// resulting mismatch by padding the tail with silence (audio) /
    /// transparency (video). Returns true if any clip was extended.
    /// Idempotent — re-running on an already-padded project is a no-op.
    @discardableResult
    private static func extendShortNonScreenClipsToCanonicalTimeline(into project: inout Project) -> Bool {
        // Longest screen-track clip's timeline-range END (start + duration).
        var longestScreenEndSeconds: Double = 0
        for track in project.tracks where track.kind == .screen {
            for clip in track.clips {
                let endSec = clip.timelineRange.start.seconds + clip.timelineRange.duration.seconds
                if endSec > longestScreenEndSeconds {
                    longestScreenEndSeconds = endSec
                }
            }
        }
        guard longestScreenEndSeconds > 0 else { return false }
        let canonicalTimescale = project.tracks
            .first(where: { $0.kind == .screen })?
            .clips.first?
            .timelineRange.duration.timescale ?? 600

        var changed = false
        for trackIdx in project.tracks.indices {
            // Skip screen tracks (they ARE the canonical reference).
            // Skip effects + overlay tracks (no source material to pad).
            switch project.tracks[trackIdx].kind {
            case .screen, .effects, .overlay:
                continue
            case .webcam, .microphone, .systemAudio, .voiceover:
                break
            }
            // Find the next clip's start time on this track for each
            // index — when present, that's the hard upper bound on
            // how far we can extend the current clip. Without this
            // check the heal would stretch scene 1's clip across
            // scene 2's range on a scenes-merged project, producing
            // overlapping audio ramps (which AVMutableAudioMix then
            // rejects) and a broken preview render.
            let clipStartsByIndex: [Int: Double] = Dictionary(
                uniqueKeysWithValues: project.tracks[trackIdx].clips.enumerated().map {
                    ($0.offset, $0.element.timelineRange.start.seconds)
                }
            )
            for clipIdx in project.tracks[trackIdx].clips.indices {
                let clip = project.tracks[trackIdx].clips[clipIdx]
                let currentEnd = clip.timelineRange.start.seconds + clip.timelineRange.duration.seconds
                // Determine the next clip on this track (lowest start
                // time strictly greater than this clip's). Multi-clip
                // tracks (scenes-merged) must not stretch into the
                // following clip's range.
                let currentStart = clip.timelineRange.start.seconds
                let nextStart = clipStartsByIndex
                    .filter { $0.key != clipIdx && $0.value > currentStart }
                    .map { $0.value }
                    .min()
                let upperBound = nextStart ?? longestScreenEndSeconds
                // Only extend when the clip currently ends before the
                // available upper bound, AND the user hasn't set an
                // explicit speed (which would imply they want the
                // current timeline duration).
                guard currentEnd + 0.05 < upperBound else { continue }
                guard clip.speed == 1.0 else { continue }
                let newDurationSeconds = upperBound - currentStart
                let newDuration = RationalTime(
                    value: Int64((newDurationSeconds * Double(canonicalTimescale)).rounded()),
                    timescale: canonicalTimescale
                )
                project.tracks[trackIdx].clips[clipIdx].timelineRange = TimeRange(
                    start: clip.timelineRange.start,
                    duration: newDuration
                )
                changed = true
            }
        }
        return changed
    }

    /// Walks each track and shrinks any clip whose `timelineRange.end`
    /// extends past the next clip's `timelineRange.start` on the same
    /// track. Returns true if any clip was shrunk. Idempotent.
    ///
    /// Why this is here: the previous version of
    /// `extendShortNonScreenClipsToCanonicalTimeline` stretched every
    /// non-screen clip to `longestScreenEndSeconds` without checking
    /// for subsequent clips, so scenes-merged projects landed scene 1's
    /// audio/cam clip on top of scene 2's. AVMutableAudioMix rejects
    /// overlapping volume ramps; the Metal compositor errors out with
    /// `missingScreenLayer` when two clips are stacked. This repair
    /// pass restores correct timeline ranges on projects already
    /// written to disk in the bad state.
    @discardableResult
    private static func shrinkOverlappingClipsOnSameTrack(into project: inout Project) -> Bool {
        var changed = false
        for trackIdx in project.tracks.indices {
            // Snapshot (index, start, end) and sort by start so we can
            // walk pairs (cur, next) and shrink cur when it overlaps.
            let clipMetrics = project.tracks[trackIdx].clips.enumerated().map {
                (
                    idx: $0.offset,
                    start: $0.element.timelineRange.start.seconds,
                    end: $0.element.timelineRange.start.seconds
                        + $0.element.timelineRange.duration.seconds
                )
            }
            let sorted = clipMetrics.sorted { $0.start < $1.start }
            guard sorted.count > 1 else { continue }
            for i in 0..<(sorted.count - 1) {
                let cur = sorted[i]
                let next = sorted[i + 1]
                // 1 ms slop — adjacent clips touching at the same time
                // are not overlapping (matches the half-open
                // `[start, end)` convention in TimeRange.overlaps).
                guard cur.end > next.start + 0.001 else { continue }
                let newDurationSeconds = next.start - cur.start
                guard newDurationSeconds > 0 else { continue }
                let oldRange = project.tracks[trackIdx].clips[cur.idx].timelineRange
                let timescale = oldRange.duration.timescale
                let newDuration = RationalTime(
                    value: Int64((newDurationSeconds * Double(timescale)).rounded()),
                    timescale: timescale
                )
                project.tracks[trackIdx].clips[cur.idx].timelineRange = TimeRange(
                    start: oldRange.start,
                    duration: newDuration
                )
                changed = true
            }
        }
        return changed
    }

    private static func synthesizeTracksFromAssets(into project: inout Project) {
        // Canonical timeline length: the longest screen asset's duration
        // (screens are the most reliable indicator of recording length),
        // falling back to the longest asset across all kinds. Every
        // synthesized clip gets this duration as its `timelineRange.duration`
        // so a cam / mic file that's shorter than the screen still claims
        // the full recording on the timeline. PreviewComposition pads the
        // tail with empty / silence when `clip.speed == 1.0` and the
        // source is shorter than the timeline — see
        // `populateVideoTrack` / `populateAudioTrack`.
        let screenDurations = project.assets
            .filter { $0.kind == .display }
            .map { $0.nativeDuration.seconds }
        let canonicalSeconds: Double = {
            if let longestScreen = screenDurations.max(), longestScreen > 0 {
                return longestScreen
            }
            return project.assets.map { $0.nativeDuration.seconds }.max() ?? 0
        }()
        let canonicalDuration: RationalTime = canonicalSeconds > 0
            ? .seconds(canonicalSeconds)
            : .zero

        for asset in project.assets where asset.nativeDuration.value > 0 {
            let kind: TrackKind
            let name: String
            switch asset.kind {
            case .display: kind = .screen; name = "Screen"
            case .webcam: kind = .webcam; name = "Webcam"
            case .microphone: kind = .microphone; name = "Microphone"
            case .systemAudio: kind = .systemAudio; name = "System Audio"
            case .voiceover: kind = .voiceover; name = "Voiceover"
            case .imported, .window, .area, .device:
                // These don't have an obvious 1:1 track mapping in v0.1.
                // Skipped here; user can wire them up by hand later.
                continue
            }
            let sourceRange = TimeRange(start: .zero, duration: asset.nativeDuration)
            let timelineDur: RationalTime =
                canonicalDuration.seconds > asset.nativeDuration.seconds
                ? canonicalDuration
                : asset.nativeDuration
            let timelineRange = TimeRange(start: .zero, duration: timelineDur)
            let clip = Clip(
                assetID: asset.id,
                sourceRange: sourceRange,
                timelineRange: timelineRange
            )
            project.tracks.append(Track(kind: kind, name: name, clips: [clip]))
        }
    }

    private func refreshFromHistory() async {
        self.project = await history.project
        self.canUndo = await history.canUndo
        self.canRedo = await history.canRedo
        self.undoActionName = await history.undoActionName
        self.redoActionName = await history.redoActionName
    }
}
