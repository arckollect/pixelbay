import Foundation
import PixelbayCore

// Phase 5 — Scenes merge. Pure function over Project: walks
// `project.scenesSession?.scenes` in display order, skipping scenes whose
// `activeTake == nil`, and inserts the active takes' assets back-to-back on
// shared tracks (one Track per relevant `TrackKind`). After all scenes are
// processed, clears `project.scenesSession` so the resulting Project decodes
// as a normal timeline-editable document on the next load.
//
// Locked design decisions referenced inline:
//  - #4 (single shared track set, scene clips back-to-back, one Track per
//    TrackKind): matches Phase 2's multi-clip-per-track model.
//  - #7 (description → `clip.extras["sceneDescription"]`): non-empty only.
//    `clip.extras["sceneID"]` is always stamped for back-reference.
//  - #9 (discarded takes kept in the bundle): we DON'T touch
//    `project.assets`; the Cleanup command in slice 5.7 is the only
//    pruning path.
//  - #14 (Merge skips empty scenes; UI confirms before doing so): caller
//    surfaces the count via the return value.
//
// Canonical scene duration = the screen asset's `nativeDuration` when the
// take has one; otherwise the longest asset duration in the take (safe
// fallback for audio-only / degenerate scenes — every scene a user actually
// records has at least one screen asset).

public enum ScenesMerger {

    public enum MergeError: Error, CustomStringConvertible {
        case noScenesSession
        case assetMissing(MediaAssetID)
        case takeHasNoAssets(SceneID)

        public var description: String {
            switch self {
            case .noScenesSession:
                return "Project has no scenesSession to merge"
            case .assetMissing(let id):
                return "MediaAsset \(id.rawValue) referenced by an active Take is not in project.assets"
            case .takeHasNoAssets(let id):
                return "Active Take for scene \(id.rawValue) has no assetIDs"
            }
        }
    }

    /// Walks `project.scenesSession` in display order, mutating `project`
    /// in place. Returns the number of scenes actually merged (== number of
    /// scenes whose `activeTake` was non-nil and contributed at least one
    /// clip).
    ///
    /// Idempotency: this is a one-way operation — after merge,
    /// `project.scenesSession == nil`. Calling `merge` on a project that's
    /// already merged throws `.noScenesSession`. The caller is expected to
    /// run this exactly once per scenes-bundle lifecycle, then open the
    /// resulting project in a normal editor window.
    @discardableResult
    public static func merge(into project: inout Project) throws -> Int {
        guard let session = project.scenesSession else {
            throw MergeError.noScenesSession
        }

        var mergedSceneCount = 0
        var runningOffsetSeconds: Double = 0
        // (kind → existing track index). Built lazily: first scene that has an
        // asset of a given kind creates the track; subsequent scenes append.
        var trackIndexByKind: [TrackKind: Int] = [:]

        // Asset lookup table — Project.locateClip-style helper, but for assets
        // by ID. Built once up front because every take iteration walks it.
        let assetByID: [MediaAssetID: MediaAsset] = Dictionary(
            project.assets.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        for scene in session.scenes {
            guard let take = scene.activeTake else { continue }
            if take.assetIDs.isEmpty {
                throw MergeError.takeHasNoAssets(scene.id)
            }

            // Validate every asset exists before mutating tracks. Throwing
            // late would leave the project half-merged.
            var takeAssets: [MediaAsset] = []
            takeAssets.reserveCapacity(take.assetIDs.count)
            for assetID in take.assetIDs {
                guard let asset = assetByID[assetID] else {
                    throw MergeError.assetMissing(assetID)
                }
                takeAssets.append(asset)
            }

            // Scene duration is the screen asset's nativeDuration when there
            // is one; else the longest asset in the take. Stays in seconds
            // for the running-offset math because mixed-timescale arithmetic
            // is an editor concern, not a merge concern.
            let screenAsset = takeAssets.first { Self.trackKind(for: $0.kind) == .screen }
            let sceneDurationSeconds = screenAsset?.nativeDuration.seconds
                ?? takeAssets.map { $0.nativeDuration.seconds }.max()
                ?? 0

            let timelineStart = RationalTime.seconds(runningOffsetSeconds)

            for asset in takeAssets {
                guard let kind = Self.trackKind(for: asset.kind) else { continue }

                // Resolve or create the shared track for this kind.
                let trackIdx: Int
                if let existing = trackIndexByKind[kind] {
                    trackIdx = existing
                } else {
                    let newTrack = Track(
                        kind: kind,
                        name: Self.defaultTrackName(for: kind)
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

                // Clamp clip duration to the canonical scene duration so
                // back-to-back scenes on shared tracks never produce
                // overlapping clips (which AVMutableAudioMix's volume-ramp
                // setter rejects with NSInvalidArgumentException). For
                // recordings made on 2026-05-27 or later, the AV pipeline
                // starts BEFORE SCStream — cam.mov / mic.caf land a small
                // amount of warm-up content at the start, so the natural
                // duration can exceed the screen recording's duration.
                // Using the *tail* of the source (sourceRange.start =
                // nativeDuration − sceneDuration) aligns playback with the
                // screen's wall-clock content: the warm-up frames are
                // skipped over and the cam / mic / sysAudio content the
                // user actually intends to keep lines up with what was
                // on screen.
                //
                // For sources shorter than the scene's canonical duration
                // (rare — happens when a writer stops early), we use the
                // whole source and let the timeline tail render
                // empty/silent through the existing pad-with-empty path
                // in PreviewComposition.
                let assetSeconds = asset.nativeDuration.seconds
                let clampedSeconds = min(assetSeconds, sceneDurationSeconds)
                let sourceStartSeconds = max(0, assetSeconds - clampedSeconds)
                let sourceStart = RationalTime.seconds(sourceStartSeconds)
                let sourceDuration = RationalTime.seconds(clampedSeconds)
                let timelineDuration = RationalTime.seconds(sceneDurationSeconds)

                let clip = Clip(
                    assetID: asset.id,
                    sourceRange: TimeRange(
                        start: sourceStart,
                        duration: sourceDuration
                    ),
                    timelineRange: TimeRange(
                        start: timelineStart,
                        duration: timelineDuration
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

    // MARK: - Mapping helpers

    /// Maps a capture-source asset kind to the shared `TrackKind` that holds
    /// merged clips. Returns nil for kinds that the scenes pipeline shouldn't
    /// place onto a shared track (e.g. `.imported`, which isn't part of a
    /// recorded Take).
    public static func trackKind(for kind: CaptureSourceKind) -> TrackKind? {
        switch kind {
        case .display, .window, .area, .device:
            return .screen
        case .webcam:
            return .webcam
        case .microphone:
            return .microphone
        case .systemAudio:
            return .systemAudio
        case .voiceover:
            return .voiceover
        case .imported:
            // A user-imported video is footage: it lives on the Video row
            // alongside screen recordings (ProjectDocument.importVideoFile).
            return .screen
        }
    }

    public static func defaultTrackName(for kind: TrackKind) -> String {
        switch kind {
        case .screen:       return "Screen"
        case .webcam:       return "Webcam"
        case .microphone:   return "Microphone"
        case .systemAudio:  return "System Audio"
        case .voiceover:    return "Voiceover"
        case .overlay:      return "Overlay"
        case .effects:      return "Effects"
        }
    }
}
