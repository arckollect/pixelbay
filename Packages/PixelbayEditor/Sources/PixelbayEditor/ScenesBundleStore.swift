import Foundation
import PixelbayCore

// Phase 5 — persistence helpers for the scenes-session bundle. Split out
// of the @MainActor app-target model so the file/Codable bits are testable
// in PixelbayEditor's existing test target. The model wraps these calls
// behind a debounced @Observable surface; the underlying disk layout is
// fully exercised here.
//
// Bundle policy (decision #16 in the plan):
//   - ONE persistent `.pixelbay` bundle at `defaultBundleURL`.
//   - On open: if it exists AND `project.scenesSession != nil` → reuse.
//   - On open: if it exists AND `scenesSession == nil` (means the previous
//     session was merged) → archive to `Archive/scenes-{timestamp}.pixelbay`
//     and create a fresh one with `ScenesSession.freshDefault()`.
//   - On open: if it doesn't exist → create fresh.
// The archive-on-merge step is what gives us "the bundle starts clean for
// each scenes session" without losing the previously merged recordings.

public enum ScenesBundleStore {

    public enum StoreError: Error, CustomStringConvertible {
        case projectMissingScenesSessionAfterCreate

        public var description: String {
            switch self {
            case .projectMissingScenesSessionAfterCreate:
                return "Internal invariant violated: freshly created scenes bundle is missing its scenesSession field"
            }
        }
    }

    // MARK: - Default paths

    /// `~/Library/Application Support/Pixelbay/Scenes/scenes-session.pixelbay`.
    /// Resolves on every call rather than being cached so a test or non-default
    /// `FileManager` can intercept it; production callers go through the
    /// `openOrCreatePersistent(at:)` overload that uses this as its default.
    public static func defaultBundleURL(fileManager: FileManager = .default) throws -> URL {
        try defaultScenesDirectory(fileManager: fileManager)
            .appendingPathComponent("scenes-session.pixelbay")
    }

    /// `~/Library/Application Support/Pixelbay/Scenes/Archive/`. Where
    /// merged bundles get moved before a fresh one is created in their place.
    public static func defaultArchiveDirectory(fileManager: FileManager = .default) throws -> URL {
        try defaultScenesDirectory(fileManager: fileManager)
            .appendingPathComponent("Archive", isDirectory: true)
    }

    /// `~/Library/Application Support/Pixelbay/Recordings/`. Where the
    /// standalone scenes merge lands the resulting bundle so each merge
    /// produces a uniquely-named editable project alongside normal
    /// single-shot recordings.
    public static func defaultRecordingsDirectory(fileManager: FileManager = .default) throws -> URL {
        try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        .appendingPathComponent("Pixelbay/Recordings", isDirectory: true)
    }

    private static func defaultScenesDirectory(fileManager: FileManager) throws -> URL {
        try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        .appendingPathComponent("Pixelbay/Scenes", isDirectory: true)
    }

    public static func archiveFilename(for date: Date) -> String {
        "scenes-\(archiveTimestampFormatter.string(from: date)).pixelbay"
    }

    public static func mergedFilename(for date: Date) -> String {
        "scenes-merged-\(archiveTimestampFormatter.string(from: date)).pixelbay"
    }

    private static let archiveTimestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    // MARK: - Open / Create / Archive

    public struct OpenResult: Equatable, Sendable {
        public let bundle: ProjectBundle
        public let session: ScenesSession
        /// True iff a previous (merged) bundle was archived before this one
        /// was created. Surfaces to the model so the UI can log/announce the
        /// archive on first open if it wants to. `false` for the cold-start
        /// path AND for the "already-active session, just reload" path.
        public let didArchivePreviousBundle: Bool

        // Equatable on ProjectBundle is trivial (URL only).
        public static func == (lhs: OpenResult, rhs: OpenResult) -> Bool {
            lhs.bundle.url == rhs.bundle.url
                && lhs.didArchivePreviousBundle == rhs.didArchivePreviousBundle
                // ScenesSession isn't Equatable yet (Date fields make this
                // noisy); compare scene-count + defaults for a useful spot
                // check without dragging Equatable into ScenesSession.
                && lhs.session.scenes.count == rhs.session.scenes.count
                && lhs.session.defaults == rhs.session.defaults
        }
    }

    /// Opens the persistent scenes bundle at `bundleURL`, creating it (or
    /// archiving the previous merged version and creating a fresh one) as
    /// needed. Returns the bundle + the live ScenesSession copy. Pure file
    /// I/O — call from a background queue if you care about not blocking
    /// the main thread (the model debounces).
    public static func openOrCreatePersistent(
        at bundleURL: URL,
        archiveDirectory: URL,
        store: ProjectBundleStore = ProjectBundleStore(),
        fileManager: FileManager = .default,
        now: Date = Date()
    ) throws -> OpenResult {
        if fileManager.fileExists(atPath: bundleURL.path) {
            let bundle = ProjectBundle(url: bundleURL)
            let project: Project
            do {
                project = try store.loadProject(from: bundle)
            } catch {
                // Corrupt project.json — archive the wreck and start fresh
                // rather than locking the user out of scenes mode entirely.
                try fileManager.createDirectory(at: archiveDirectory, withIntermediateDirectories: true)
                let archived = archiveDirectory.appendingPathComponent(archiveFilename(for: now))
                try fileManager.moveItem(at: bundleURL, to: archived)
                let fresh = try createFreshBundle(at: bundleURL, store: store, now: now)
                return OpenResult(bundle: fresh.bundle, session: fresh.session, didArchivePreviousBundle: true)
            }

            if let session = project.scenesSession {
                return OpenResult(
                    bundle: bundle,
                    session: session,
                    didArchivePreviousBundle: false
                )
            }

            // Previous session was merged (scenesSession cleared by
            // ScenesMerger). Archive the merged bundle and create a fresh
            // one so the next scenes session doesn't inherit old media.
            try fileManager.createDirectory(at: archiveDirectory, withIntermediateDirectories: true)
            let archived = archiveDirectory.appendingPathComponent(archiveFilename(for: now))
            try fileManager.moveItem(at: bundleURL, to: archived)
            let fresh = try createFreshBundle(at: bundleURL, store: store, now: now)
            return OpenResult(bundle: fresh.bundle, session: fresh.session, didArchivePreviousBundle: true)
        }

        // Cold start.
        let fresh = try createFreshBundle(at: bundleURL, store: store, now: now)
        return OpenResult(bundle: fresh.bundle, session: fresh.session, didArchivePreviousBundle: false)
    }

    /// Moves a just-merged scenes bundle out of the `scenes-session.pixelbay`
    /// slot into a uniquely-named bundle under `recordingsDirectory`,
    /// returning the new URL. Two reasons the standalone merge path uses
    /// this:
    ///  (1) Every merge gets a distinct URL, so the
    ///      `ProjectWindowID(bundleURL:)` passed to SwiftUI's
    ///      `openWindow(value:)` is distinct per merge — without this,
    ///      `WindowGroup(for: ProjectWindowID.self)` reused a
    ///      previously-discarded editor's scene state across merges and
    ///      surfaced the OLD recording in the new editor window.
    ///  (2) Merged projects land alongside standalone recordings so
    ///      File > Open and orphan recovery see them.
    ///
    /// On filename collision (two merges in the same wall-second), appends
    /// a numeric suffix `-1`, `-2`, … until a free path is found. Throws
    /// only on filesystem failure (mkdir / moveItem).
    public static func relocateMergedBundleToRecordings(
        from bundleURL: URL,
        recordingsDirectory: URL,
        fileManager: FileManager = .default,
        now: Date = Date()
    ) throws -> URL {
        try fileManager.createDirectory(
            at: recordingsDirectory,
            withIntermediateDirectories: true
        )
        let baseName = mergedFilename(for: now)
        var candidate = recordingsDirectory.appendingPathComponent(baseName)
        if fileManager.fileExists(atPath: candidate.path) {
            // Strip ".pixelbay" → append "-N" → re-append ".pixelbay".
            let stem = (baseName as NSString).deletingPathExtension
            var suffix = 1
            repeat {
                candidate = recordingsDirectory
                    .appendingPathComponent("\(stem)-\(suffix).pixelbay")
                suffix += 1
            } while fileManager.fileExists(atPath: candidate.path)
        }
        try fileManager.moveItem(at: bundleURL, to: candidate)
        return candidate
    }

    private static func createFreshBundle(
        at bundleURL: URL,
        store: ProjectBundleStore,
        now: Date
    ) throws -> (bundle: ProjectBundle, session: ScenesSession) {
        // Ensure the parent (Scenes/) dir exists.
        try FileManager.default.createDirectory(
            at: bundleURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let session = ScenesSession.freshDefault(now: now)
        let project = Project(
            name: "Scenes Session \(archiveTimestampFormatter.string(from: now))",
            createdAt: now,
            modifiedAt: now,
            scenesSession: session
        )
        let bundle = try store.createBundle(at: bundleURL, project: project)
        return (bundle, session)
    }

    // MARK: - Persist

    /// Loads `bundle/project.json`, replaces `project.scenesSession` with
    /// the supplied value, and writes back atomically. Used by the model on
    /// every debounced write tick after a user mutation. Preserves
    /// `project.assets` so recordings made between persists aren't lost.
    public static func persistSession(
        _ session: ScenesSession,
        in bundle: ProjectBundle,
        store: ProjectBundleStore = ProjectBundleStore()
    ) throws {
        var project = try store.loadProject(from: bundle)
        var updated = session
        updated.modifiedAt = Date()
        project.scenesSession = updated
        try store.writeProject(project, to: bundle)
    }

    // MARK: - Cleanup

    public struct CleanupReport: Equatable, Sendable {
        public let removedAssetIDs: [MediaAssetID]
        public let removedFilePaths: [String]
        public init(
            removedAssetIDs: [MediaAssetID] = [],
            removedFilePaths: [String] = []
        ) {
            self.removedAssetIDs = removedAssetIDs
            self.removedFilePaths = removedFilePaths
        }
    }

    /// Removes media files + `MediaAsset` entries for inactive scene takes
    /// (decision #9: discarded takes stay around until the user explicitly
    /// asks for cleanup). Operates on the in-memory `Project`; the caller
    /// is responsible for re-persisting and refreshing the model's session
    /// copy from the result. Sidecar files matching the same sessionID
    /// (e.g. `clicks-{sessionID}.json`) are removed alongside each media
    /// file so orphaned sidecars don't pile up.
    ///
    /// Works in two modes. When `project.scenesSession` is non-nil, walks
    /// every scene's takes and drops the inactive ones. When it's nil
    /// (e.g. a project that's already been through `ScenesMerger`), only
    /// the orphan sweep runs — any `MediaAsset` not referenced by a Clip
    /// (or by an active take in a non-merged session) gets pruned. So a
    /// user can run "Clean up unused takes" on a merged scenes project to
    /// reclaim the disk space their discarded takes still occupy.
    @discardableResult
    public static func cleanupUnusedTakes(
        in project: inout Project,
        bundleURL: URL,
        fileManager: FileManager = .default,
        deleteFilesImmediately: Bool = true
    ) throws -> CleanupReport {
        var session: ScenesSession? = project.scenesSession

        // Step 1 — collect every assetID referenced by an ACTIVE take in
        // the scenes session (if there is one). Any asset NOT in this set,
        // but present in a scene's takes list, is orphaned.
        var keepAssetIDs: Set<MediaAssetID> = []
        if let session {
            for scene in session.scenes {
                if let take = scene.activeTake {
                    keepAssetIDs.formUnion(take.assetIDs)
                }
            }
        }
        // Also keep anything referenced by a Clip — post-merge projects
        // store the canonical "this asset matters" signal here. Also a
        // safety net for scenes-mode bundles if the caller has added
        // Tracks mid-merge (e.g. crash recovery).
        for track in project.tracks {
            for clip in track.clips {
                keepAssetIDs.insert(clip.assetID)
            }
        }

        var removedAssetIDs: [MediaAssetID] = []
        var removedFilePaths: [String] = []
        // Need to map MediaAssetID → MediaAsset for the file URL lookup
        // before mutating project.assets.
        let assetByID = Dictionary(
            project.assets.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        // Step 2 — walk each scene's takes; drop inactive ones; capture
        // their assets for removal. Only runs when scenesSession is set;
        // post-merge projects skip straight to the orphan sweep below.
        if var live = session {
            for sceneIdx in live.scenes.indices {
                var scene = live.scenes[sceneIdx]
                let activeID = scene.activeTake?.id
                scene.takes.removeAll { take in
                    if take.id == activeID { return false }
                    for assetID in take.assetIDs where !keepAssetIDs.contains(assetID) {
                        removedAssetIDs.append(assetID)
                    }
                    return true
                }
                // activeTakeIndex may now be stale — re-resolve against the
                // new takes array.
                if let id = activeID, let idx = scene.takes.firstIndex(where: { $0.id == id }) {
                    scene.activeTakeIndex = idx
                } else {
                    scene.activeTakeIndex = scene.takes.isEmpty ? nil : 0
                }
                live.scenes[sceneIdx] = scene
            }
            session = live
        }

        // Step 3 — collect orphan files (media + matching sidecars by
        // sessionID prefix) and remove the assets from project.assets.
        let bundle = ProjectBundle(url: bundleURL)
        var distinctRemovedIDs = Set(removedAssetIDs)
        // Step 4 — also include any assets in project.assets that aren't
        // referenced by either a kept take OR a clip. Belt-and-suspenders
        // for orphans created by direct project edits.
        for asset in project.assets where !keepAssetIDs.contains(asset.id) {
            distinctRemovedIDs.insert(asset.id)
        }

        for id in distinctRemovedIDs {
            guard let asset = assetByID[id] else { continue }
            guard let mediaURL = try? bundle.url(forRelativePath: asset.relativePath) else { continue }
            if fileManager.fileExists(atPath: mediaURL.path) {
                removedFilePaths.append(asset.relativePath)
            }
            // Best-effort sidecar cleanup: anything in media/ matching the
            // file's stem prefix gets removed too (covers `clicks-{id}.json`,
            // `thumb-{id}.png`, etc.). We scan the asset's containing dir.
            let containingDir = mediaURL.deletingLastPathComponent()
            let stem = (asset.relativePath as NSString).lastPathComponent
            if let sessionPrefix = extractSessionPrefix(from: stem),
               let siblings = try? fileManager.contentsOfDirectory(at: containingDir, includingPropertiesForKeys: nil)
            {
                for sibling in siblings where sibling.lastPathComponent.contains(sessionPrefix)
                    && sibling.lastPathComponent != stem
                {
                    // Only remove sidecars whose entire filename ties back
                    // to this sessionID (`clicks-{prefix}.json`,
                    // `thumb-{prefix}.png`); don't yank an unrelated take's
                    // file just because the prefix substring happens to
                    // appear in its name.
                    if sibling.lastPathComponent.range(of: sessionPrefix) != nil {
                        let bundlePath = bundle.url.standardizedFileURL.path + "/"
                        let siblingPath = sibling.standardizedFileURL.path
                        if siblingPath.hasPrefix(bundlePath) {
                            removedFilePaths.append(String(siblingPath.dropFirst(bundlePath.count)))
                        }
                    }
                }
            }
        }

        // Remove orphan assets from the model.
        project.assets.removeAll { distinctRemovedIDs.contains($0.id) }
        if session != nil {
            project.scenesSession = session
        }

        let report = CleanupReport(
            removedAssetIDs: Array(distinctRemovedIDs),
            removedFilePaths: removedFilePaths
        )
        if deleteFilesImmediately {
            try deleteCleanupFiles(report, bundleURL: bundleURL, fileManager: fileManager)
        }
        return report
    }

    /// Deletes files listed by a `cleanupUnusedTakes` report. Kept separate
    /// so app code can first persist the pruned `project.json`, then commit
    /// disk cleanup without risking a project that still references media
    /// files already removed from disk.
    public static func deleteCleanupFiles(
        _ report: CleanupReport,
        bundleURL: URL,
        fileManager: FileManager = .default
    ) throws {
        let bundle = ProjectBundle(url: bundleURL)
        for relativePath in report.removedFilePaths {
            let url = try bundle.url(forRelativePath: relativePath)
            if fileManager.fileExists(atPath: url.path) {
                try fileManager.removeItem(at: url)
            }
        }
    }

    /// Pulls the `{sessionID}` slug out of a filename like
    /// `screen-abcd1234.mov` → `abcd1234`. Returns nil for filenames that
    /// don't match the `{kind}-{sessionID}.{ext}` convention `RecordingService`
    /// produces. Defensive: a malformed name shouldn't take down cleanup.
    public static func extractSessionPrefix(from filename: String) -> String? {
        guard let dashIdx = filename.firstIndex(of: "-") else { return nil }
        let afterDash = filename.index(after: dashIdx)
        guard let dotIdx = filename.firstIndex(of: ".") else { return nil }
        guard afterDash < dotIdx else { return nil }
        let prefix = String(filename[afterDash..<dotIdx])
        return prefix.isEmpty ? nil : prefix
    }
}
