import XCTest
@testable import PixelbayEditor
import PixelbayCore

final class ScenesBundleStoreTests: XCTestCase {

    private var tempDir: URL!
    private var bundleURL: URL!
    private var archiveDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("scenes-bundle-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        bundleURL = tempDir.appendingPathComponent("scenes-session.pixelbay")
        archiveDir = tempDir.appendingPathComponent("Archive", isDirectory: true)
    }

    override func tearDownWithError() throws {
        if let url = tempDir {
            try? FileManager.default.removeItem(at: url)
        }
    }

    // MARK: - openOrCreatePersistent

    func test_open_coldStart_createsFreshBundleWithThreeEmptyScenes() throws {
        let now = Date()
        let result = try ScenesBundleStore.openOrCreatePersistent(
            at: bundleURL,
            archiveDirectory: archiveDir,
            now: now
        )

        XCTAssertFalse(result.didArchivePreviousBundle)
        XCTAssertEqual(result.session.scenes.count, 3)
        for scene in result.session.scenes {
            XCTAssertTrue(scene.takes.isEmpty)
            XCTAssertNil(scene.activeTakeIndex)
        }
        // Bundle dirs exist on disk.
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.bundle.url.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.bundle.projectFileURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.bundle.mediaDirectoryURL.path))

        // project.json contains a non-nil scenesSession.
        let project = try ProjectBundleStore().loadProject(from: result.bundle)
        XCTAssertNotNil(project.scenesSession)
    }

    func test_open_reopensExistingBundle_preservingScenesSession() throws {
        let now = Date()
        let first = try ScenesBundleStore.openOrCreatePersistent(
            at: bundleURL,
            archiveDirectory: archiveDir,
            now: now
        )
        // Mutate, persist, reopen.
        var session = first.session
        session.scenes.append(Scene(description: "Outro"))
        try ScenesBundleStore.persistSession(session, in: first.bundle)

        let reopened = try ScenesBundleStore.openOrCreatePersistent(
            at: bundleURL,
            archiveDirectory: archiveDir,
            now: now.addingTimeInterval(60)
        )
        XCTAssertFalse(reopened.didArchivePreviousBundle)
        XCTAssertEqual(reopened.session.scenes.count, 4)
        XCTAssertEqual(reopened.session.scenes.last?.description, "Outro")
    }

    func test_open_archivesMergedBundle_andCreatesFreshOne() throws {
        let now = Date()
        let first = try ScenesBundleStore.openOrCreatePersistent(
            at: bundleURL,
            archiveDirectory: archiveDir,
            now: now
        )
        // Simulate the merge step having cleared scenesSession.
        var project = try ProjectBundleStore().loadProject(from: first.bundle)
        project.scenesSession = nil
        try ProjectBundleStore().writeProject(project, to: first.bundle)

        let archiveStamp = now.addingTimeInterval(120)
        let result = try ScenesBundleStore.openOrCreatePersistent(
            at: bundleURL,
            archiveDirectory: archiveDir,
            now: archiveStamp
        )
        XCTAssertTrue(result.didArchivePreviousBundle)
        XCTAssertEqual(result.session.scenes.count, 3)

        // Archive dir contains exactly one archived bundle with the
        // expected filename.
        let archived = try FileManager.default.contentsOfDirectory(at: archiveDir, includingPropertiesForKeys: nil)
        XCTAssertEqual(archived.count, 1)
        XCTAssertEqual(archived.first?.lastPathComponent, ScenesBundleStore.archiveFilename(for: archiveStamp))

        // The new bundle at bundleURL is a fresh one (different ProjectID
        // than the archived one).
        let freshProject = try ProjectBundleStore().loadProject(from: result.bundle)
        XCTAssertNotNil(freshProject.scenesSession)
    }

    func test_open_archivesCorruptBundle_andCreatesFreshOne() throws {
        // Pre-existing path with a broken project.json — the open helper
        // must archive and recover rather than throw and lock the user out.
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let badProjectFile = bundleURL.appendingPathComponent("project.json")
        try Data("not json".utf8).write(to: badProjectFile)

        let now = Date()
        let result = try ScenesBundleStore.openOrCreatePersistent(
            at: bundleURL,
            archiveDirectory: archiveDir,
            now: now
        )
        XCTAssertTrue(result.didArchivePreviousBundle)
        XCTAssertEqual(result.session.scenes.count, 3)
        // Archive received the corrupt bundle.
        let archived = try FileManager.default.contentsOfDirectory(at: archiveDir, includingPropertiesForKeys: nil)
        XCTAssertEqual(archived.count, 1)
    }

    // MARK: - persistSession

    func test_persistSession_writesUpdatedScenesSessionAndPreservesAssets() throws {
        let now = Date()
        let first = try ScenesBundleStore.openOrCreatePersistent(
            at: bundleURL,
            archiveDirectory: archiveDir,
            now: now
        )
        // Pretend RecordingService appended an asset to project.assets
        // (it does that via writeProjectAndReport in scenes mode).
        var project = try ProjectBundleStore().loadProject(from: first.bundle)
        let injectedAsset = MediaAsset(
            kind: .display,
            relativePath: "media/screen-xxxxxxxx.mov",
            nativeDuration: .seconds(7)
        )
        project.assets.append(injectedAsset)
        try ProjectBundleStore().writeProject(project, to: first.bundle)

        // Now have the model persist a session mutation. The pre-existing
        // asset must survive.
        var session = first.session
        session.scenes[0].description = "Hello"
        try ScenesBundleStore.persistSession(session, in: first.bundle)

        let reloaded = try ProjectBundleStore().loadProject(from: first.bundle)
        XCTAssertEqual(reloaded.scenesSession?.scenes.first?.description, "Hello")
        XCTAssertEqual(reloaded.assets.count, 1)
        XCTAssertEqual(reloaded.assets.first?.relativePath, "media/screen-xxxxxxxx.mov")
    }

    // MARK: - cleanupUnusedTakes

    func test_cleanup_removesInactiveTakesAssetsAndFiles() throws {
        let now = Date()
        let opened = try ScenesBundleStore.openOrCreatePersistent(
            at: bundleURL,
            archiveDirectory: archiveDir,
            now: now
        )
        let bundle = opened.bundle

        // Synthesize: scene with two takes; the second is active. Each
        // take has one screen asset + one sidecar.
        let oldScreenID = MediaAssetID.generate()
        let oldScreenPath = "media/screen-oldsessn.mov"
        let oldClicksPath = "media/clicks-oldsessn.json"
        let oldAsset = MediaAsset(
            id: oldScreenID,
            kind: .display,
            relativePath: oldScreenPath,
            nativeDuration: .seconds(5)
        )
        try Data("fake mov".utf8).write(to: bundle.url.appendingPathComponent(oldScreenPath))
        try Data("[]".utf8).write(to: bundle.url.appendingPathComponent(oldClicksPath))

        let newScreenID = MediaAssetID.generate()
        let newScreenPath = "media/screen-newsessn.mov"
        let newClicksPath = "media/clicks-newsessn.json"
        let newAsset = MediaAsset(
            id: newScreenID,
            kind: .display,
            relativePath: newScreenPath,
            nativeDuration: .seconds(6)
        )
        try Data("fake mov".utf8).write(to: bundle.url.appendingPathComponent(newScreenPath))
        try Data("[]".utf8).write(to: bundle.url.appendingPathComponent(newClicksPath))

        let oldTake = Take(sessionID: "oldsessn", assetIDs: [oldScreenID], durationSeconds: 5)
        let newTake = Take(sessionID: "newsessn", assetIDs: [newScreenID], durationSeconds: 6)
        let scene = Scene(takes: [oldTake, newTake], activeTakeIndex: 1)

        var project = try ProjectBundleStore().loadProject(from: bundle)
        project.assets.append(contentsOf: [oldAsset, newAsset])
        project.scenesSession = ScenesSession(scenes: [scene])
        try ProjectBundleStore().writeProject(project, to: bundle)

        // Re-load (simulates the model handing us back a fresh project copy)
        // and run cleanup.
        var live = try ProjectBundleStore().loadProject(from: bundle)
        let report = try ScenesBundleStore.cleanupUnusedTakes(
            in: &live,
            bundleURL: bundle.url
        )

        XCTAssertTrue(report.removedAssetIDs.contains(oldScreenID),
                      "old screen asset must be in the removed set")
        XCTAssertFalse(report.removedAssetIDs.contains(newScreenID),
                       "active take's asset must survive")

        // Files on disk: old removed, new survives. Sidecar matched by
        // sessionID prefix also removed.
        XCTAssertFalse(FileManager.default.fileExists(atPath: bundle.url.appendingPathComponent(oldScreenPath).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: bundle.url.appendingPathComponent(oldClicksPath).path),
                       "matching clicks-oldsessn.json sidecar should be removed too")
        XCTAssertTrue(FileManager.default.fileExists(atPath: bundle.url.appendingPathComponent(newScreenPath).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: bundle.url.appendingPathComponent(newClicksPath).path))

        // project.assets shrunk to just the active take's asset.
        XCTAssertEqual(live.assets.count, 1)
        XCTAssertEqual(live.assets.first?.id, newScreenID)

        // scenesSession's scene now has exactly one take (the active one),
        // with activeTakeIndex re-pointed at it.
        XCTAssertEqual(live.scenesSession?.scenes.first?.takes.count, 1)
        XCTAssertEqual(live.scenesSession?.scenes.first?.activeTakeIndex, 0)
    }

    func test_cleanup_isNoopWhenNoScenesSession_andNoOrphans() throws {
        var project = Project(name: "Plain")
        let report = try ScenesBundleStore.cleanupUnusedTakes(
            in: &project,
            bundleURL: tempDir
        )
        XCTAssertTrue(report.removedAssetIDs.isEmpty)
        XCTAssertTrue(report.removedFilePaths.isEmpty)
    }

    func test_cleanup_postMerge_removesOrphanedAssetsAndFiles() throws {
        // After ScenesMerger runs, project.scenesSession is nil. Any
        // MediaAsset in project.assets that ISN'T referenced by a Clip is
        // a discarded take's leftover and should be reclaimable by this
        // command.
        let now = Date()
        let opened = try ScenesBundleStore.openOrCreatePersistent(
            at: bundleURL,
            archiveDirectory: archiveDir,
            now: now
        )
        let bundle = opened.bundle

        // Simulate the post-merge state: write a project with one screen
        // track + clip referencing one asset, plus a second "orphan" asset
        // representing a discarded take.
        let keepID = MediaAssetID.generate()
        let keepAsset = MediaAsset(
            id: keepID,
            kind: .display,
            relativePath: "media/screen-keep.mov",
            nativeDuration: .seconds(5)
        )
        try Data("kept".utf8).write(to: bundle.url.appendingPathComponent("media/screen-keep.mov"))

        let orphanID = MediaAssetID.generate()
        let orphanAsset = MediaAsset(
            id: orphanID,
            kind: .display,
            relativePath: "media/screen-discarded.mov",
            nativeDuration: .seconds(5)
        )
        try Data("discarded".utf8).write(to: bundle.url.appendingPathComponent("media/screen-discarded.mov"))

        var project = try ProjectBundleStore().loadProject(from: bundle)
        project.assets = [keepAsset, orphanAsset]
        project.tracks = [
            Track(
                kind: .screen,
                name: "Screen",
                clips: [Clip(
                    assetID: keepID,
                    sourceRange: TimeRange(start: .zero, duration: .seconds(5)),
                    timelineRange: TimeRange(start: .zero, duration: .seconds(5))
                )]
            )
        ]
        project.scenesSession = nil       // post-merge state
        try ProjectBundleStore().writeProject(project, to: bundle)

        var live = try ProjectBundleStore().loadProject(from: bundle)
        let report = try ScenesBundleStore.cleanupUnusedTakes(
            in: &live,
            bundleURL: bundle.url
        )

        XCTAssertTrue(report.removedAssetIDs.contains(orphanID),
                      "discarded screen asset must be removed post-merge")
        XCTAssertFalse(report.removedAssetIDs.contains(keepID),
                       "asset referenced by a clip must survive")
        XCTAssertFalse(FileManager.default.fileExists(atPath: bundle.url.appendingPathComponent("media/screen-discarded.mov").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: bundle.url.appendingPathComponent("media/screen-keep.mov").path))
        XCTAssertEqual(live.assets.count, 1)
        XCTAssertEqual(live.assets.first?.id, keepID)
        XCTAssertNil(live.scenesSession)
    }

    func test_cleanup_preservesAssetsReferencedByClips() throws {
        // Belt-and-suspenders: if some clip in project.tracks points at an
        // asset that's NOT referenced by an active take, don't delete it.
        let now = Date()
        let opened = try ScenesBundleStore.openOrCreatePersistent(
            at: bundleURL,
            archiveDirectory: archiveDir,
            now: now
        )
        let bundle = opened.bundle
        var live = try ProjectBundleStore().loadProject(from: bundle)

        let clipAssetID = MediaAssetID.generate()
        let clipAsset = MediaAsset(
            id: clipAssetID,
            kind: .display,
            relativePath: "media/screen-clipped.mov",
            nativeDuration: .seconds(3)
        )
        try Data("fake".utf8).write(to: bundle.url.appendingPathComponent("media/screen-clipped.mov"))
        let clip = Clip(
            assetID: clipAssetID,
            sourceRange: TimeRange(start: .zero, duration: .seconds(3)),
            timelineRange: TimeRange(start: .zero, duration: .seconds(3))
        )
        let track = Track(kind: .screen, name: "Screen", clips: [clip])
        live.assets.append(clipAsset)
        live.tracks.append(track)
        // No scene references this asset — but the clip does.

        let report = try ScenesBundleStore.cleanupUnusedTakes(
            in: &live,
            bundleURL: bundle.url
        )
        XCTAssertFalse(report.removedAssetIDs.contains(clipAssetID))
        XCTAssertTrue(live.assets.contains(where: { $0.id == clipAssetID }))
    }

    // MARK: - extractSessionPrefix helper

    func test_extractSessionPrefix_parsesStandardFilenames() {
        XCTAssertEqual(ScenesBundleStore.extractSessionPrefix(from: "screen-abcd1234.mov"), "abcd1234")
        XCTAssertEqual(ScenesBundleStore.extractSessionPrefix(from: "clicks-abcd1234.json"), "abcd1234")
        XCTAssertEqual(ScenesBundleStore.extractSessionPrefix(from: "thumb-deadbeef.png"), "deadbeef")
    }

    func test_extractSessionPrefix_returnsNilForMalformedNames() {
        XCTAssertNil(ScenesBundleStore.extractSessionPrefix(from: "noextension"))
        XCTAssertNil(ScenesBundleStore.extractSessionPrefix(from: "no-extension"))
        XCTAssertNil(ScenesBundleStore.extractSessionPrefix(from: ".dotfile"))
    }

    // MARK: - relocateMergedBundleToRecordings (standalone merge URL freshness)

    func test_relocate_movesBundleToTimestampedNameUnderRecordings() throws {
        // Seed a scenes-session.pixelbay with a sentinel marker file we can
        // re-check at the destination — proves the move carried bundle
        // contents, not just the directory shell.
        let recordingsDir = tempDir.appendingPathComponent("Recordings", isDirectory: true)
        try seedFakeMergedBundle(at: bundleURL, marker: "marker-A")

        let stamp = Date()
        let movedURL = try ScenesBundleStore.relocateMergedBundleToRecordings(
            from: bundleURL,
            recordingsDirectory: recordingsDir,
            now: stamp
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: bundleURL.path),
                       "scenes-session slot must be empty after relocate")
        XCTAssertTrue(FileManager.default.fileExists(atPath: movedURL.path),
                      "merged bundle must exist at the new URL")
        XCTAssertEqual(movedURL.lastPathComponent,
                       ScenesBundleStore.mergedFilename(for: stamp))
        XCTAssertEqual(movedURL.deletingLastPathComponent().path,
                       recordingsDir.path)
        // Marker survived the move → bundle contents were moved, not lost.
        let markerData = try Data(contentsOf: movedURL.appendingPathComponent("marker.txt"))
        XCTAssertEqual(String(data: markerData, encoding: .utf8), "marker-A")
    }

    func test_relocate_twoMergesProduceDifferentURLs_evenAtSameTimestamp() throws {
        // The crux of the user-facing fix: every standalone merge must
        // yield a distinct URL so the SwiftUI `ProjectWindowID` differs
        // between sessions. The previous-merge editor cannot be reused
        // with stale @State.
        let recordingsDir = tempDir.appendingPathComponent("Recordings", isDirectory: true)
        let now = Date()

        // Merge #1.
        try seedFakeMergedBundle(at: bundleURL, marker: "merge-1")
        let firstURL = try ScenesBundleStore.relocateMergedBundleToRecordings(
            from: bundleURL,
            recordingsDirectory: recordingsDir,
            now: now
        )

        // Merge #2 — same wall-second; helper must collision-avoid.
        try seedFakeMergedBundle(at: bundleURL, marker: "merge-2")
        let secondURL = try ScenesBundleStore.relocateMergedBundleToRecordings(
            from: bundleURL,
            recordingsDirectory: recordingsDir,
            now: now
        )

        XCTAssertNotEqual(firstURL, secondURL,
                          "two merges at the same wall-second must produce distinct URLs")
        // Both files survive at their respective URLs — neither overwrote
        // the other.
        XCTAssertTrue(FileManager.default.fileExists(atPath: firstURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: secondURL.path))
        let firstMarker = try Data(contentsOf: firstURL.appendingPathComponent("marker.txt"))
        let secondMarker = try Data(contentsOf: secondURL.appendingPathComponent("marker.txt"))
        XCTAssertEqual(String(data: firstMarker, encoding: .utf8), "merge-1")
        XCTAssertEqual(String(data: secondMarker, encoding: .utf8), "merge-2")
    }

    func test_relocate_freesSceneSessionSlot_so_nextOpenIsColdStart() throws {
        // End-to-end of the user scenario: merge → the slot at
        // scenes-session.pixelbay is empty → next openOrCreatePersistent
        // goes through the cold-start branch (didArchivePreviousBundle =
        // false) instead of trying to archive a left-behind merged bundle.
        let recordingsDir = tempDir.appendingPathComponent("Recordings", isDirectory: true)
        try seedFakeMergedBundle(at: bundleURL, marker: "first-session")

        _ = try ScenesBundleStore.relocateMergedBundleToRecordings(
            from: bundleURL,
            recordingsDirectory: recordingsDir,
            now: Date()
        )

        // Now simulate the user reopening the scenes window.
        let reopened = try ScenesBundleStore.openOrCreatePersistent(
            at: bundleURL,
            archiveDirectory: archiveDir,
            now: Date()
        )
        XCTAssertFalse(reopened.didArchivePreviousBundle,
                       "next scenes open must be cold-start, not archive-on-merge")
        XCTAssertEqual(reopened.session.scenes.count, 3,
                       "cold-start yields three fresh empty scenes")
    }

    // Builds a minimal valid `.pixelbay` directory at `url` with a marker
    // file inside so a subsequent move can be verified to have carried the
    // bundle contents (not just renamed an empty directory).
    private func seedFakeMergedBundle(at url: URL, marker: String) throws {
        let project = Project(
            name: "Test Merged",
            createdAt: Date(),
            modifiedAt: Date()
        )
        _ = try ProjectBundleStore().createBundle(at: url, project: project)
        try Data(marker.utf8).write(to: url.appendingPathComponent("marker.txt"))
    }

    // MARK: - End-to-end: the exact user bug scenario at the disk layer

    /// Simulates the reported bug at the on-disk layer: first scenes
    /// recording → merge → discard the editor → second scenes recording →
    /// merge. Without the fix, both merges landed at the SAME
    /// `scenes-session.pixelbay` URL, producing identical
    /// `ProjectWindowID` values and triggering SwiftUI window-state
    /// reuse. With the fix, each merge moves its bundle to a distinct
    /// URL under `Recordings/` (and the second merge gets the SECOND
    /// session's content, not a leftover of the first).
    func test_endToEnd_twoMergeCycles_produceDistinctRecordingsAndDistinctContent() throws {
        let recordingsDir = tempDir.appendingPathComponent("Recordings", isDirectory: true)
        let bundleStore = ProjectBundleStore()

        // ────────── Cycle 1: scenes session A → merge → discard ──────────
        let openA = try ScenesBundleStore.openOrCreatePersistent(
            at: bundleURL,
            archiveDirectory: archiveDir,
            now: Date()
        )
        // Inject session A: one scene with one screen asset → one take.
        var projectA = try bundleStore.loadProject(from: openA.bundle)
        let screenAID = MediaAssetID.generate()
        projectA.assets.append(MediaAsset(
            id: screenAID,
            kind: .display,
            relativePath: "media/screen-cycleA.mov",
            nativeDuration: .seconds(4)
        ))
        var sessionA = openA.session
        sessionA.scenes[0].takes.append(Take(
            sessionID: "cycleA",
            assetIDs: [screenAID],
            durationSeconds: 4
        ))
        sessionA.scenes[0].activeTakeIndex = 0
        projectA.scenesSession = sessionA
        try bundleStore.writeProject(projectA, to: openA.bundle)
        // Drop a fake media file so a real on-disk presence backs the asset.
        try Data("fake-mov-cycleA".utf8).write(
            to: openA.bundle.url.appendingPathComponent("media/screen-cycleA.mov")
        )

        // Run the merge: ScenesMerger then relocate.
        var mergeProjectA = try bundleStore.loadProject(from: openA.bundle)
        _ = try ScenesMerger.merge(into: &mergeProjectA)
        try bundleStore.writeProject(mergeProjectA, to: openA.bundle)
        let mergedURL1 = try ScenesBundleStore.relocateMergedBundleToRecordings(
            from: openA.bundle.url,
            recordingsDirectory: recordingsDir,
            now: Date()
        )

        // After cycle 1: scenes-session.pixelbay does NOT exist; merged
        // bundle 1 lives under Recordings/ and carries cycle A's screen
        // asset + merged track.
        XCTAssertFalse(FileManager.default.fileExists(atPath: bundleURL.path))
        let merged1 = try bundleStore.loadProject(from: ProjectBundle(url: mergedURL1))
        XCTAssertEqual(merged1.assets.count, 1)
        XCTAssertEqual(merged1.assets.first?.relativePath, "media/screen-cycleA.mov")
        XCTAssertEqual(merged1.tracks.flatMap { $0.clips }.count, 1)
        XCTAssertNil(merged1.scenesSession)

        // User "discards" the editor — at the disk layer this is a no-op
        // because no edit was ever saved. The on-disk merged file
        // persists (consistent with how all unsaved-then-closed projects
        // behave; they remain on disk for File > Open recovery).

        // ────────── Cycle 2: scenes session B → merge ──────────
        let openB = try ScenesBundleStore.openOrCreatePersistent(
            at: bundleURL,
            archiveDirectory: archiveDir,
            now: Date()
        )
        // Critical assertion #1: the cycle-2 scenes-window-open did NOT
        // need to archive anything — the slot was already empty after
        // cycle 1's relocate. This proves the bug-precondition is gone.
        XCTAssertFalse(openB.didArchivePreviousBundle,
                       "Cycle 2 must be a clean cold-start (the relocate freed the slot)")

        var projectB = try bundleStore.loadProject(from: openB.bundle)
        let screenBID = MediaAssetID.generate()
        projectB.assets.append(MediaAsset(
            id: screenBID,
            kind: .display,
            relativePath: "media/screen-cycleB.mov",
            nativeDuration: .seconds(6)
        ))
        var sessionB = openB.session
        sessionB.scenes[0].takes.append(Take(
            sessionID: "cycleB",
            assetIDs: [screenBID],
            durationSeconds: 6
        ))
        sessionB.scenes[0].activeTakeIndex = 0
        projectB.scenesSession = sessionB
        try bundleStore.writeProject(projectB, to: openB.bundle)
        try Data("fake-mov-cycleB".utf8).write(
            to: openB.bundle.url.appendingPathComponent("media/screen-cycleB.mov")
        )

        var mergeProjectB = try bundleStore.loadProject(from: openB.bundle)
        _ = try ScenesMerger.merge(into: &mergeProjectB)
        try bundleStore.writeProject(mergeProjectB, to: openB.bundle)
        let mergedURL2 = try ScenesBundleStore.relocateMergedBundleToRecordings(
            from: openB.bundle.url,
            recordingsDirectory: recordingsDir,
            now: Date()
        )

        // Critical assertion #2: the two merged URLs are DISTINCT — the
        // SwiftUI ProjectWindowID values cannot collide → a fresh editor
        // window will be created on the second openWindow(value:) call.
        XCTAssertNotEqual(mergedURL1, mergedURL2,
                          "Each merge must produce a distinct URL so the editor window cannot be reused")

        // Critical assertion #3: the second merged bundle carries
        // CYCLE B's content (the new recording), not lingering cycle A
        // content. This is what the user expected ("show me only the new
        // recording").
        let merged2 = try bundleStore.loadProject(from: ProjectBundle(url: mergedURL2))
        XCTAssertEqual(merged2.assets.count, 1,
                       "Cycle 2's merged bundle must carry only its own asset")
        XCTAssertEqual(merged2.assets.first?.relativePath, "media/screen-cycleB.mov",
                       "Cycle 2's merged bundle must reference the cycle-B media, NOT cycle-A's")
        XCTAssertEqual(merged2.tracks.flatMap { $0.clips }.count, 1)
        XCTAssertNil(merged2.scenesSession)

        // Both merged bundles continue to coexist on disk — the user can
        // still recover the discarded cycle-A merge via File > Open if
        // they change their mind (no destructive cleanup on discard).
        XCTAssertTrue(FileManager.default.fileExists(atPath: mergedURL1.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: mergedURL2.path))
    }
}
