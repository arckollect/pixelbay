import AVFoundation
import AppKit
import Foundation
import Observation
import OSLog
import PixelbayCore
import PixelbayEditor
import SwiftUI

private let log = Logger(subsystem: "com.pixelbay.PixelbayApp", category: "ScenesSessionModel")

// Phase 5 — orchestration model behind the Scenes window. Wraps the
// persistent .pixelbay bundle (at `~/Library/Application Support/Pixelbay/
// Scenes/scenes-session.pixelbay`) and exposes mutations the UI binds to
// via @Observable. Recording integration (recordScene wiring) is wired in
// slice 5.6; this slice owns the model shape + persistence flow so the UI
// slice (5.5) and the recording slice (5.6) have a stable place to land.
//
// Persistence: every mutation calls `persistDebounced()`, which schedules
// a write 250 ms in the future and coalesces successive calls (the user
// typing in a description field shouldn't trigger one disk write per
// keystroke). The actual disk work goes through `ScenesBundleStore` in
// PixelbayEditor — that's where the persistence semantics live and where
// they're tested.

@MainActor
@Observable
final class ScenesSessionModel {

    enum Phase: Equatable {
        case idle
        case recordingScene(sceneIndex: Int, startedAt: Date)
        case finalizing
        case merged(bundleURL: URL)
        case failed(message: String)
    }

    var phase: Phase = .idle
    var session: ScenesSession
    private(set) var bundle: ProjectBundle

    /// Slice A.2 — when non-nil, this model was opened "from the editor"
    /// against a specific editor document. The History section in the UI
    /// reconstructs from this project's clips (grouped by
    /// `clip.extras["sceneID"]`), and the merge path runs
    /// `mergeAppendingTo(document:)` instead of `merge(opening:)`. The
    /// scenes-session.pixelbay bundle still backs NEW scenes; merge writes
    /// the appended scenes into the editor's project, then clears
    /// `project.scenesSession` on the scenes bundle so the next session
    /// starts fresh.
    var appendTarget: ProjectDocument?

    /// History rows reconstructed from `appendTarget.project`. Each row
    /// represents one scene's worth of already-merged clips in the editor.
    /// Cached so the UI binds without re-walking tracks per render. Refreshed
    /// whenever `appendTarget`'s project changes or the model loads.
    var historyRows: [HistoryRow] = []

    private let recording: RecordingService
    private let store = ProjectBundleStore()
    private var persistTask: Task<Void, Never>?
    private static let persistDebounceNanoseconds: UInt64 = 250_000_000

    /// Read-only representation of a previously-merged scene in an editor's
    /// project. The user can edit the description (writes through
    /// `SetClipExtraCommand` on every clip in the group) and reorder
    /// (`MoveClipsByGroupCommand`) but cannot delete or re-record from this
    /// row — those are timeline-editor operations, not scenes-window ones.
    struct HistoryRow: Identifiable, Hashable {
        let id: String         // sceneID raw value
        let description: String
        let clipIDs: [ClipID]
        let startSeconds: Double
        let durationSeconds: Double
        let thumbnailRelativePath: String?
    }

    private init(
        session: ScenesSession,
        bundle: ProjectBundle,
        recording: RecordingService,
        appendTarget: ProjectDocument? = nil
    ) {
        self.session = session
        self.bundle = bundle
        self.recording = recording
        self.appendTarget = appendTarget
        if let appendTarget {
            self.historyRows = Self.discoverHistoryRows(in: appendTarget.project)
        }
    }

    /// Async factory — opens (or archives + recreates) the persistent
    /// scenes-session bundle and returns a fresh model bound to it. Throws
    /// if the bundle can't be opened (corrupt + cannot archive). UI calls
    /// this once per scenes-window-launch.
    static func openOrCreatePersistent(
        recording: RecordingService
    ) async throws -> ScenesSessionModel {
        // Hop to a background task for the disk work so callers in the
        // SwiftUI window-open path don't see hitches on a slow disk.
        let bundleURL = try ScenesBundleStore.defaultBundleURL()
        let archiveDir = try ScenesBundleStore.defaultArchiveDirectory()
        let opened = try await Task.detached(priority: .userInitiated) {
            try ScenesBundleStore.openOrCreatePersistent(
                at: bundleURL,
                archiveDirectory: archiveDir
            )
        }.value
        if opened.didArchivePreviousBundle {
            log.info("archived previous (merged) scenes bundle on open")
        }
        return ScenesSessionModel(
            session: opened.session,
            bundle: opened.bundle,
            recording: recording
        )
    }

    /// Slice A.2 factory — opens the persistent scenes-session bundle in
    /// "append" mode against an existing editor document. Behaves like
    /// `openOrCreatePersistent` for the persistent bundle (so NEW scenes
    /// get recorded into the same scenes-session.pixelbay as always); the
    /// difference is the model carries an `appendTarget` reference and a
    /// reconstructed History row set built from the editor's project.
    static func openForAppendingTo(
        document: ProjectDocument,
        recording: RecordingService
    ) async throws -> ScenesSessionModel {
        let bundleURL = try ScenesBundleStore.defaultBundleURL()
        let archiveDir = try ScenesBundleStore.defaultArchiveDirectory()
        let opened = try await Task.detached(priority: .userInitiated) {
            try ScenesBundleStore.openOrCreatePersistent(
                at: bundleURL,
                archiveDirectory: archiveDir
            )
        }.value
        if opened.didArchivePreviousBundle {
            log.info("archived previous (merged) scenes bundle on open (append-mode)")
        }
        return ScenesSessionModel(
            session: opened.session,
            bundle: opened.bundle,
            recording: recording,
            appendTarget: document
        )
    }

    /// Re-walk `appendTarget.project` and rebuild the cached `historyRows`.
    /// Call after the editor document's revision changes (e.g. the user
    /// edited a description on a history row through this model's
    /// `updateHistoryDescription` API).
    func refreshHistoryRows() {
        guard let appendTarget else {
            historyRows = []
            return
        }
        historyRows = Self.discoverHistoryRows(in: appendTarget.project)
    }

    private static func discoverHistoryRows(in project: Project) -> [HistoryRow] {
        // Group clips by sceneID; sort each group by earliest timelineRange
        // start. Read description from `clip.extras["sceneDescription"]`
        // (any clip in the group will do — they're all stamped identically
        // by ScenesMerger). Thumbnail relative path is best-effort sourced
        // from the project's matching scenesSession Take when one survives
        // (rare — merge clears scenesSession), else nil.
        struct Bucket {
            var clipIDs: [ClipID] = []
            var description: String = ""
            var start: Double = .greatestFiniteMagnitude
            var end: Double = 0
        }
        var byID: [String: Bucket] = [:]
        for track in project.tracks {
            for clip in track.clips {
                guard case .string(let id)? = clip.extras["sceneID"] else { continue }
                var bucket = byID[id] ?? Bucket()
                bucket.clipIDs.append(clip.id)
                if case .string(let desc)? = clip.extras["sceneDescription"] {
                    bucket.description = desc
                }
                let startSec = clip.timelineRange.start.seconds
                let endSec = startSec + clip.timelineRange.duration.seconds
                bucket.start = min(bucket.start, startSec)
                bucket.end = max(bucket.end, endSec)
                byID[id] = bucket
            }
        }
        return byID
            .map { id, bucket in
                HistoryRow(
                    id: id,
                    description: bucket.description,
                    clipIDs: bucket.clipIDs,
                    startSeconds: bucket.start.isFinite ? bucket.start : 0,
                    durationSeconds: max(0, bucket.end - bucket.start),
                    thumbnailRelativePath: nil
                )
            }
            .sorted { $0.startSeconds < $1.startSeconds }
    }

    // MARK: - Scene-level mutations

    func addScene() {
        session.scenes.append(Scene())
        persistDebounced()
    }

    func deleteScene(at index: Int) {
        guard session.scenes.indices.contains(index) else { return }
        session.scenes.remove(at: index)
        persistDebounced()
    }

    func moveScene(from source: Int, to destination: Int) {
        guard session.scenes.indices.contains(source) else { return }
        // SwiftUI .onMove uses "to: insertion-point" semantics; convert to
        // an Array-friendly source/destination move.
        var clamped = destination
        if clamped > session.scenes.count { clamped = session.scenes.count }
        let scene = session.scenes.remove(at: source)
        let insertAt = (clamped > source) ? clamped - 1 : clamped
        session.scenes.insert(scene, at: insertAt)
        persistDebounced()
    }

    func updateDescription(sceneID: SceneID, to text: String) {
        guard let idx = session.scenes.firstIndex(where: { $0.id == sceneID }) else { return }
        if session.scenes[idx].description == text { return }
        session.scenes[idx].description = text
        persistDebounced()
    }

    func updateSourceOverride(sceneID: SceneID, _ override: SceneSourceOverride) {
        guard let idx = session.scenes.firstIndex(where: { $0.id == sceneID }) else { return }
        if session.scenes[idx].sourceOverride == override { return }
        session.scenes[idx].sourceOverride = override
        persistDebounced()
    }

    func updateDefaults(_ defaults: ScenesGlobalDefaults) {
        if session.defaults == defaults { return }
        session.defaults = defaults
        persistDebounced()
    }

    // MARK: - Take-level mutations

    func setActiveTake(sceneID: SceneID, takeIndex: Int) {
        guard let sceneIdx = session.scenes.firstIndex(where: { $0.id == sceneID }) else { return }
        let scene = session.scenes[sceneIdx]
        guard scene.takes.indices.contains(takeIndex) else { return }
        if session.scenes[sceneIdx].activeTakeIndex == takeIndex { return }
        session.scenes[sceneIdx].activeTakeIndex = takeIndex
        persistDebounced()
    }

    func deleteTake(sceneID: SceneID, takeID: TakeID) {
        guard let sceneIdx = session.scenes.firstIndex(where: { $0.id == sceneID }) else { return }
        guard let takeIdx = session.scenes[sceneIdx].takes.firstIndex(where: { $0.id == takeID }) else { return }
        let wasActive = session.scenes[sceneIdx].activeTakeIndex == takeIdx
        session.scenes[sceneIdx].takes.remove(at: takeIdx)
        if wasActive {
            // Re-point activeTakeIndex onto whatever's left (last
            // recording, since takes are in chronological order). Nil
            // when the scene is now empty.
            session.scenes[sceneIdx].activeTakeIndex = session.scenes[sceneIdx].takes.isEmpty
                ? nil
                : session.scenes[sceneIdx].takes.count - 1
        } else if let current = session.scenes[sceneIdx].activeTakeIndex,
                  current > takeIdx {
            // Shift active index left to compensate for the removed entry.
            session.scenes[sceneIdx].activeTakeIndex = current - 1
        }
        persistDebounced()
    }

    // MARK: - Recording integration

    /// Drives a single-scene recording through RecordingService. Computes
    /// the effective `StartRequest` from `session.defaults` overlaid with
    /// `scenes[index].sourceOverride`, transitions to `.recordingScene`
    /// (so the window collapses to compact HUD), starts the recording,
    /// awaits the user's stop, then appends a fresh `Take` to the scene
    /// from the resulting `Result.assetIDs`. Extracts a first-frame
    /// thumbnail via `AVAssetImageGenerator` and stamps the relative path
    /// onto the Take. Finally acknowledges the result on the recording
    /// service so the next call's `canStartRecording` flips back to true.
    func recordScene(at index: Int) async {
        guard session.scenes.indices.contains(index) else { return }
        guard case .idle = phase else {
            log.notice("recordScene rejected — phase=\(String(describing: self.phase), privacy: .public)")
            return
        }
        let scene = session.scenes[index]
        let request = makeStartRequest(
            defaults: session.defaults,
            override: scene.sourceOverride
        )
        guard let request else {
            phase = .failed(message: "No display selected. Pick one in the defaults section before recording.")
            return
        }

        phase = .recordingScene(sceneIndex: index, startedAt: Date())
        await recording.start(request, existingBundle: bundle, sceneLabel: "Scene \(index + 1)")

        // Wait for the user to stop. `recording.stop()` is called from the
        // HUD button or the ⌃⌘. hotkey — we just observe phase here. Poll
        // because RecordingService is @Observable but doesn't expose an
        // AsyncSequence of transitions; 80 ms is fast enough that the UI
        // hop back from compact HUD to full window feels instant on stop.
        let pollNanoseconds: UInt64 = 80_000_000
        var terminal: RecordingService.Phase = .idle
        wait: while !Task.isCancelled {
            switch recording.phase {
            case .stopped, .failed, .idle:
                terminal = recording.phase
                break wait
            default:
                try? await Task.sleep(nanoseconds: pollNanoseconds)
            }
        }

        switch terminal {
        case .stopped(let result):
            await handleSceneRecordingDidStop(result: result, sceneIndex: index)
        case .failed(let message):
            phase = .failed(message: message)
            recording.acknowledgeResult()
        default:
            // Includes .idle (user-acknowledged before we reached this
            // point, e.g. a tearDown race). Just reset.
            phase = .idle
        }
    }

    private func handleSceneRecordingDidStop(
        result: RecordingService.Result,
        sceneIndex: Int
    ) async {
        defer { recording.acknowledgeResult() }
        phase = .finalizing

        // Build the Take. Use the screen duration when present (canonical
        // scene length); fall back to the overall recording duration.
        let take = Take(
            recordedAt: Date(),
            sessionID: result.sessionID,
            assetIDs: result.assetIDs,
            durationSeconds: result.screenDurationSeconds ?? result.durationSeconds,
            thumbnailRelativePath: nil
        )

        guard session.scenes.indices.contains(sceneIndex) else {
            phase = .idle
            return
        }
        session.scenes[sceneIndex].takes.append(take)
        session.scenes[sceneIndex].activeTakeIndex = session.scenes[sceneIndex].takes.count - 1

        // Extract first-frame thumbnail off the main actor so the UI hop
        // back from compact HUD isn't blocked on AVAssetImageGenerator's
        // synchronous decode. Stamp the resulting relative path back into
        // the Take and persist.
        if let relativePath = await extractThumbnail(
            for: result.screenURL,
            sessionID: result.sessionID,
            in: bundle
        ) {
            let lastIdx = session.scenes[sceneIndex].takes.count - 1
            if session.scenes[sceneIndex].takes.indices.contains(lastIdx) {
                session.scenes[sceneIndex].takes[lastIdx].thumbnailRelativePath = relativePath
            }
        }

        phase = .idle
        // Flush immediately rather than debouncing — the user just finished
        // a recording and may close the window or hit ⌘Q.
        do {
            try persistNow()
        } catch {
            log.error("post-record persist failed: \(String(describing: error), privacy: .public)")
        }
    }

    private func makeStartRequest(
        defaults: ScenesGlobalDefaults,
        override: SceneSourceOverride
    ) -> RecordingService.StartRequest? {
        let displayID = override.displayID ?? defaults.displayID
        guard let displayID else { return nil }
        let includeSysAudio = override.includeSystemAudio ?? defaults.includeSystemAudio
        // Pull globalBounds from the live source catalog when we can; the
        // model doesn't own a catalog, so a fresh per-call enumeration via
        // NSScreen is cheap and avoids cross-actor coupling.
        let bounds = Self.displayBounds(for: displayID)
        return RecordingService.StartRequest(
            displayID: displayID,
            displayPointsBounds: bounds,
            cameraID: override.cameraUniqueID ?? defaults.cameraUniqueID,
            micID: override.micUniqueID ?? defaults.micUniqueID,
            includeSystemAudio: includeSysAudio,
            logClicks: defaults.logClicks,
            appendTracks: false       // scenes mode — ScenesMerger builds tracks
        )
    }

    private static func displayBounds(for displayID: CGDirectDisplayID) -> CGRect? {
        for screen in NSScreen.screens {
            if let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
               id == displayID
            {
                return screen.frame
            }
        }
        return nil
    }

    /// Reads the first frame of `screenURL` and writes a thumbnail PNG to
    /// `bundle/media/thumb-{sessionID}.png`. Returns the relative path so
    /// the caller can stamp it onto `Take.thumbnailRelativePath`. Failures
    /// (file missing, decoder rejected, write failed) return nil — a Scene
    /// row gracefully falls back to the placeholder icon.
    private func extractThumbnail(
        for screenURL: URL,
        sessionID: String,
        in bundle: ProjectBundle
    ) async -> String? {
        let relativePath = "media/thumb-\(sessionID).png"
        let outputURL = bundle.url.appendingPathComponent(relativePath)
        do {
            try await Self.writeFirstFrameThumbnail(
                screenURL: screenURL,
                outputURL: outputURL
            )
            return relativePath
        } catch {
            log.error("thumbnail extract failed sessionID=\(sessionID, privacy: .public) error=\(String(describing: error), privacy: .public)")
            return nil
        }
    }

    private static func writeFirstFrameThumbnail(
        screenURL: URL,
        outputURL: URL
    ) async throws {
        // Run on a detached task so AVAssetImageGenerator's async sample
        // walk doesn't pin the main actor while it talks to AVFoundation.
        try await Task.detached(priority: .userInitiated) {
            let asset = AVURLAsset(url: screenURL)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            // Limit the bitmap size — thumbs render in a 56×56 slot, no
            // need for native 4K. 256pt-tall keeps Retina sharp.
            generator.maximumSize = CGSize(width: 480, height: 270)
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = CMTime(seconds: 0.5, preferredTimescale: 600)
            let (cgImage, _) = try await generator.image(at: .zero)
            // Encode to PNG and write atomically.
            let bitmap = NSBitmapImageRep(cgImage: cgImage)
            guard let pngData = bitmap.representation(using: .png, properties: [:]) else {
                throw NSError(domain: "Pixelbay.Scenes", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: "NSBitmapImageRep refused PNG encoding"
                ])
            }
            try pngData.write(to: outputURL, options: .atomic)
        }.value
    }

    // MARK: - Merge

    /// Runs `ScenesMerger.merge` on the bundle's project, moves the merged
    /// bundle out of the scenes-session slot into a uniquely-named bundle
    /// under `Recordings/`, then opens the result in a new editor window
    /// and dismisses the scenes window. Phase transitions: `idle →
    /// finalizing → merged(bundleURL)` on success; `→ failed(message)` on
    /// error.
    ///
    /// Why the move: the previous version wrote the merged project back
    /// into `scenes-session.pixelbay` and called `openWindow(value:)` with
    /// that singleton URL. `WindowGroup(for: ProjectWindowID.self)` keys
    /// windows by the hashable value, so two merges in the same app
    /// session produced the same `ProjectWindowID` — SwiftUI brought back
    /// the previously-discarded editor's scene state instead of loading
    /// the fresh project from disk, and the user saw the OLD recording's
    /// clips even though disk had the new ones. Moving the merged bundle
    /// to a unique URL gives every merge a distinct `ProjectWindowID` (no
    /// scene-state reuse), and it also makes merged projects discoverable
    /// alongside standalone recordings via File > Open.
    ///
    /// Caller passes the SwiftUI `OpenWindowAction` so the model can fire
    /// `openWindow(value: ProjectWindowID(bundleURL:))` from the same
    /// MainActor without holding a reference to SwiftUI's environment.
    /// The `onMergedDismiss` closure (typically `{ dismissWindow() }`)
    /// closes the scenes window after the editor opens — Slice A.1's fix
    /// for the dead-button "stranded after merge" bug.
    func merge(
        opening openWindow: OpenWindowAction? = nil,
        onMergedDismiss: (() -> Void)? = nil
    ) async -> Int {
        phase = .finalizing
        do {
            var project = try store.loadProject(from: bundle)
            // Sync the model's in-memory session into the on-disk project
            // before merging so any unsaved mutations get folded in.
            project.scenesSession = session
            let mergedCount = try ScenesMerger.merge(into: &project)
            try store.writeProject(project, to: bundle)

            // Move the merged bundle out of the scenes-session slot so
            // (a) every merge produces a distinct ProjectWindowID and
            // (b) the next scenes-window open sees no file at the
            // scenes-session path and goes through the cold-start
            // create-fresh branch — guaranteeing a clean session even if
            // the user discards the previous editor without saving.
            let recordingsDir = try ScenesBundleStore.defaultRecordingsDirectory()
            let mergedURL = try ScenesBundleStore.relocateMergedBundleToRecordings(
                from: bundle.url,
                recordingsDirectory: recordingsDir
            )

            phase = .merged(bundleURL: mergedURL)
            if let openWindow {
                openWindow(value: ProjectWindowID(bundleURL: mergedURL))
            }
            onMergedDismiss?()
            return mergedCount
        } catch {
            log.error("merge failed: \(String(describing: error), privacy: .public)")
            phase = .failed(message: humanReadable(error))
            return 0
        }
    }

    // MARK: - Slice A.2 — append-mode merge + history edits

    /// Append-merges the scenes-session into the captured `appendTarget`
    /// editor document. Walks new scenes via
    /// `ScenesMerger.mergeAppending(into:)` so the new clips land at the
    /// editor's existing timeline tail; the resulting tracks/clips flow
    /// through the editor's command pipeline so the operation is undoable
    /// + the editor's preview rebuilds. After a successful append, the
    /// scenes-session bundle's `project.scenesSession` is reset to a
    /// `.freshDefault()` so the next "Scenes" click sees three empty rows.
    ///
    /// Returns the number of scenes appended (matches `merge(opening:)`).
    /// Phase transitions mirror `merge` — `idle → finalizing → merged` on
    /// success, `→ failed` on error.
    func mergeAppendingTo(
        document: ProjectDocument,
        onMergedDismiss: (() -> Void)? = nil
    ) async -> Int {
        phase = .finalizing
        do {
            // Step 1: bring the scenes bundle's project up to date so the
            // assets RecordingService appended between persists are part
            // of the snapshot we hand to ScenesMerger.mergeAppending.
            try persistNow()
            var scenesProject = try store.loadProject(from: bundle)
            scenesProject.scenesSession = session

            // Step 2: copy the new scenes' assets into the editor document
            // and run `mergeAppending` against the editor's project. Both
            // sides need the assets — the scenes bundle keeps them for
            // archive, the editor document needs them for clip resolution.
            let scenesBundleURL = bundle.url
            let editorBundleURL = document.bundleURL
            // Copy each asset's media file from the scenes bundle into the
            // editor bundle (mkdir + cp), preserving relative paths so the
            // existing relativePath fields stay valid.
            for asset in scenesProject.assets {
                try Self.copyAssetIfNeeded(
                    asset: asset,
                    from: scenesBundleURL,
                    to: editorBundleURL
                )
                // Same treatment for the click-sidecar (mouse-trajectory)
                // file if one exists for this asset's session prefix —
                // CursorTrajectoryLoader needs it in the editor's bundle.
                let stem = (asset.relativePath as NSString).lastPathComponent
                if let sessionPrefix = ScenesBundleStore.extractSessionPrefix(from: stem) {
                    try? Self.copySidecarIfNeeded(
                        sessionPrefix: sessionPrefix,
                        from: scenesBundleURL,
                        to: editorBundleURL
                    )
                }
            }

            // Step 3: dispatch through the editor's command pipeline. We
            // build the merge in-memory against a snapshot of the editor's
            // current project, then ship a single `_AppendMergeCommand`
            // (defined below) that replays the diff. This keeps undo/redo
            // working uniformly.
            var snapshot = document.project
            // Carry the scenesSession + assets onto the snapshot so
            // mergeAppending has everything it needs.
            for asset in scenesProject.assets where !snapshot.assets.contains(where: { $0.id == asset.id }) {
                snapshot.assets.append(asset)
            }
            snapshot.scenesSession = scenesProject.scenesSession
            let preMergeTrackSnapshot = snapshot.tracks
            let preMergeAssetIDs = Set(document.project.assets.map(\.id))
            let mergedCount = try ScenesMerger.mergeAppending(into: &snapshot)

            // Diff the post-merge snapshot against the editor's current
            // project. Apply that diff via individual editor commands so
            // every change rides the standard undo stack.
            let postMergeTracks = snapshot.tracks
            let appendedAssetIDs = Set(snapshot.assets.map(\.id)).subtracting(preMergeAssetIDs)
            await applyAppendDiff(
                preMergeTracks: preMergeTrackSnapshot,
                postMergeTracks: postMergeTracks,
                appendedAssets: snapshot.assets.filter { appendedAssetIDs.contains($0.id) },
                document: document
            )

            // Step 4: rotate the scenes-session bundle's session to fresh
            // (next "Scenes" click sees three empty rows). Persist + reload.
            session = .freshDefault()
            scenesProject.scenesSession = session
            try store.writeProject(scenesProject, to: bundle)
            self.bundle = ProjectBundle(url: bundle.url)
            refreshHistoryRows()

            phase = .merged(bundleURL: editorBundleURL)
            onMergedDismiss?()
            return mergedCount
        } catch {
            log.error("mergeAppendingTo failed: \(String(describing: error), privacy: .public)")
            phase = .failed(message: humanReadable(error))
            return 0
        }
    }

    /// Applies the merge-append diff to `document` via the editor's
    /// command pipeline. New assets get pushed onto `document.project.assets`
    /// directly (no AddAsset command in the v0.1 command vocabulary; assets
    /// are write-once). New tracks dispatch `AddTrackCommand`; new clips
    /// dispatch `InsertClipCommand` per clip.
    private func applyAppendDiff(
        preMergeTracks: [Track],
        postMergeTracks: [Track],
        appendedAssets: [MediaAsset],
        document: ProjectDocument
    ) async {
        // Side-channel: directly extend project.assets via a dedicated
        // command (no built-in AddAsset exists; we add via a tiny inline
        // command file would be heavy — instead we use the simpler path
        // that the snapshot below carries the assets through naturally
        // when the InsertClipCommand resolves against them at apply time).
        // To stay aligned with the existing apply-via-command discipline,
        // we wrap the asset attach as a SetClipExtraCommand-shaped no-op
        // command isn't right either. The cleanest existing-vocabulary
        // path is to dispatch a small "attach assets + run diff" command
        // bundle: emit an _AppendAssetsCommand (declared in
        // EditCommands+ScenesFlow.swift) followed by track + clip ops.
        if !appendedAssets.isEmpty {
            await document.apply(_AppendAssetsCommand(assets: appendedAssets))
        }

        // Walk pre/post tracks paired by ID. New tracks (post-only) get
        // AddTrackCommand'd. Existing tracks get clip-by-clip diff.
        let preTrackIDs = Set(preMergeTracks.map(\.id))
        let preTrackByID = Dictionary(uniqueKeysWithValues: preMergeTracks.map { ($0.id, $0) })

        // Tracks new to post-merge: emit AddTrackCommand with an empty
        // clips list, then insert each clip. Track equality by .id —
        // ScenesMerger doesn't reuse pre IDs unless the kind already
        // existed, so this carves the new tracks cleanly.
        var newClipsByTrackID: [TrackID: [Clip]] = [:]
        for track in postMergeTracks {
            if preTrackIDs.contains(track.id) {
                let preTrack = preTrackByID[track.id]!
                let preClipIDs = Set(preTrack.clips.map(\.id))
                let newClips = track.clips.filter { !preClipIDs.contains($0.id) }
                if !newClips.isEmpty {
                    newClipsByTrackID[track.id] = newClips
                }
            } else {
                let emptyTrack = Track(
                    id: track.id,
                    kind: track.kind,
                    name: track.name,
                    clips: [],
                    extras: track.extras
                )
                await document.apply(AddTrackCommand(track: emptyTrack))
                if !track.clips.isEmpty {
                    newClipsByTrackID[track.id] = track.clips
                }
            }
        }

        for (trackID, clips) in newClipsByTrackID {
            for clip in clips {
                await document.apply(InsertClipCommand(trackID: trackID, clip: clip))
            }
        }
    }

    /// Copies the file at `bundle/asset.relativePath` from the scenes bundle
    /// into the editor bundle. No-op when the destination already has the
    /// file (idempotent across repeated merges or partial-failure retries).
    private static func copyAssetIfNeeded(
        asset: MediaAsset,
        from sourceBundleURL: URL,
        to targetBundleURL: URL
    ) throws {
        let srcURL = sourceBundleURL.appendingPathComponent(asset.relativePath)
        let dstURL = targetBundleURL.appendingPathComponent(asset.relativePath)
        if FileManager.default.fileExists(atPath: dstURL.path) {
            return
        }
        guard FileManager.default.fileExists(atPath: srcURL.path) else {
            // Source missing — caller's merge will throw a clearer
            // assetMissing error on the same asset.
            return
        }
        try FileManager.default.createDirectory(
            at: dstURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.copyItem(at: srcURL, to: dstURL)
    }

    /// Copies the click-sidecar (and any peers) sitting next to a session-
    /// prefixed asset. Failure is non-fatal — the editor's auto-zoom
    /// pipeline can run without the sidecar (no marks generated, fixed-
    /// centre zoom).
    private static func copySidecarIfNeeded(
        sessionPrefix: String,
        from sourceBundleURL: URL,
        to targetBundleURL: URL
    ) throws {
        let candidates = [
            "media/clicks-\(sessionPrefix).json",
            "media/thumb-\(sessionPrefix).png"
        ]
        for relative in candidates {
            let srcURL = sourceBundleURL.appendingPathComponent(relative)
            let dstURL = targetBundleURL.appendingPathComponent(relative)
            if !FileManager.default.fileExists(atPath: srcURL.path) { continue }
            if FileManager.default.fileExists(atPath: dstURL.path) { continue }
            try FileManager.default.createDirectory(
                at: dstURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try FileManager.default.copyItem(at: srcURL, to: dstURL)
        }
    }

    /// Updates the description for a history row by dispatching
    /// `SetClipExtraCommand` per clip in the group. The UI calls this from
    /// the history row's TextField onChange / onSubmit, debounced (the
    /// editor's command pipeline is fast enough that one command per
    /// keystroke would still feel fine, but the row commits on focus-loss
    /// to keep undo entries usable).
    func updateHistoryDescription(sceneID: String, to text: String) async {
        guard let appendTarget else { return }
        guard let row = historyRows.first(where: { $0.id == sceneID }) else { return }
        let value: JSONValue? = text.isEmpty ? nil : .string(text)
        for clipID in row.clipIDs {
            await appendTarget.apply(SetClipExtraCommand(
                clipID: clipID,
                key: "sceneDescription",
                value: value
            ))
        }
        refreshHistoryRows()
    }

    /// Reorders a history scene in the editor's timeline by dispatching
    /// `MoveClipsByGroupCommand`. Translates the SwiftUI `.onMove`
    /// (insertion-point) destination index into the command's
    /// `targetSceneIndex`.
    func moveHistoryRow(from source: Int, to destination: Int) async {
        guard let appendTarget else { return }
        guard historyRows.indices.contains(source) else { return }
        let movingID = historyRows[source].id
        var target = destination
        if target > historyRows.count { target = historyRows.count }
        // Convert SwiftUI insertion-point semantics to array-target index.
        let insertAt = (target > source) ? target - 1 : target
        await appendTarget.apply(MoveClipsByGroupCommand(
            sceneID: movingID,
            targetSceneIndex: insertAt
        ))
        refreshHistoryRows()
    }

    // MARK: - Cleanup

    /// Reloads the project from disk, runs cleanup, and writes back. Pulls
    /// from disk because the model's `session` mirror doesn't carry the
    /// full asset list (assets are appended by `RecordingService` and we
    /// don't shadow them).
    func cleanupUnusedTakes() async {
        do {
            var project = try store.loadProject(from: bundle)
            // Sync any unsaved session mutations before cleaning up — so an
            // active-take-set-then-cleanup races coherently.
            project.scenesSession = session
            let report = try ScenesBundleStore.cleanupUnusedTakes(
                in: &project,
                bundleURL: bundle.url
            )
            try store.writeProject(project, to: bundle)
            if let newSession = project.scenesSession {
                self.session = newSession
            }
            log.info(
                "cleanup removed assetCount=\(report.removedAssetIDs.count) fileCount=\(report.removedFilePaths.count)"
            )
        } catch {
            log.error("cleanup failed: \(String(describing: error), privacy: .public)")
            phase = .failed(message: humanReadable(error))
        }
    }

    // MARK: - Persistence

    /// Cancels any pending persist task and queues a fresh one 250 ms in
    /// the future. Successive calls within the window collapse to one
    /// write — avoids one disk write per keystroke when the user types in
    /// a description field.
    func persistDebounced() {
        persistTask?.cancel()
        let captured = session
        let captureBundle = bundle
        persistTask = Task { [store] in
            do {
                try? await Task.sleep(nanoseconds: Self.persistDebounceNanoseconds)
                if Task.isCancelled { return }
                try ScenesBundleStore.persistSession(captured, in: captureBundle, store: store)
            } catch {
                log.error("debounced persist failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// Flush any pending write immediately. Call before merge / cleanup /
    /// window-close to make sure the most recent mutation hits disk before
    /// the model is torn down.
    func persistNow() throws {
        persistTask?.cancel()
        persistTask = nil
        try ScenesBundleStore.persistSession(session, in: bundle, store: store)
    }

    private func humanReadable(_ error: Error) -> String {
        if let merge = error as? ScenesMerger.MergeError {
            return merge.description
        }
        if let bundle = error as? ProjectBundleError {
            return bundle.description
        }
        return error.localizedDescription
    }
}
