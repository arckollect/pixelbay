import XCTest
@testable import PixelbayCore

final class ProjectBundleTests: XCTestCase {

    private var tempDirectory: URL!

    override func setUpWithError() throws {
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pixelbay-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: tempDirectory,
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        if let url = tempDirectory {
            try? FileManager.default.removeItem(at: url)
        }
    }

    // MARK: - Round-trip through disk

    func test_createAndLoad_preservesProject() throws {
        let bundleURL = tempDirectory.appendingPathComponent("Demo.pixelbay")
        let store = ProjectBundleStore()

        let asset = MediaAsset(
            kind: .display,
            relativePath: "media/screen-001.mov",
            nativeDuration: .seconds(15)
        )
        let project = Project(
            name: "Demo",
            assets: [asset]
        )

        let bundle = try store.createBundle(at: bundleURL, project: project)
        XCTAssertTrue(FileManager.default.fileExists(atPath: bundle.projectFileURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: bundle.mediaDirectoryURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: bundle.thumbnailsDirectoryURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: bundle.voiceoversDirectoryURL.path))

        let reloaded = try store.loadProject(from: bundle)
        XCTAssertEqual(reloaded.id, project.id)
        XCTAssertEqual(reloaded.name, "Demo")
        XCTAssertEqual(reloaded.assets.count, 1)
        XCTAssertEqual(reloaded.assets[0].relativePath, "media/screen-001.mov")
    }

    func test_bundleRelativeURL_allowsNormalNestedPaths() throws {
        let bundle = ProjectBundle(url: tempDirectory.appendingPathComponent("Safe.pixelbay"))

        let url = try bundle.url(forRelativePath: "media/screen-001.mov")

        XCTAssertEqual(url, bundle.url.appendingPathComponent("media/screen-001.mov"))
    }

    func test_bundleRelativeURL_rejectsPathTraversalAndAbsolutePaths() {
        let bundle = ProjectBundle(url: tempDirectory.appendingPathComponent("Unsafe.pixelbay"))
        let unsafePaths = [
            "",
            "/tmp/escape.mov",
            "../escape.mov",
            "media/../escape.mov",
            "media//screen.mov",
            "media/./screen.mov",
            "media\\screen.mov",
            "media/screen.mov\u{0}"
        ]

        for path in unsafePaths {
            XCTAssertThrowsError(try bundle.url(forRelativePath: path), path) { error in
                guard case ProjectBundleError.unsafeRelativePath(let rejected) = error else {
                    return XCTFail("expected .unsafeRelativePath for \(path), got \(error)")
                }
                XCTAssertEqual(rejected, path)
            }
        }
    }

    // MARK: - Atomic save

    func test_writeProject_isAtomic_doesNotLeaveTempArtifacts() throws {
        let bundleURL = tempDirectory.appendingPathComponent("Atomic.pixelbay")
        let store = ProjectBundleStore()
        let project = Project(name: "Atomic")

        let bundle = try store.createBundle(at: bundleURL, project: project)
        try store.writeProject(project, to: bundle)
        try store.writeProject(project, to: bundle)
        try store.writeProject(project, to: bundle)

        let contents = try FileManager.default.contentsOfDirectory(
            at: bundle.url,
            includingPropertiesForKeys: nil
        )
        let leftoverTempFiles = contents.filter { $0.lastPathComponent.hasPrefix(".project.json.tmp-") }
        XCTAssertEqual(leftoverTempFiles, [],
                       "atomic write must not leave .project.json.tmp-* files behind")
    }

    func test_writeProject_replaceFailure_removesTempArtifact() throws {
        let bundleURL = tempDirectory.appendingPathComponent("FailingAtomic.pixelbay")
        let bundle = ProjectBundle(url: bundleURL)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        try "{}".write(to: bundle.projectFileURL, atomically: true, encoding: .utf8)

        struct ReplaceFailed: Error {}
        let wrapper = FileManagerWrapper(
            fileExists: { FileManager.default.fileExists(atPath: $0) },
            createDirectory: { url, intermediates in
                try FileManager.default.createDirectory(
                    at: url,
                    withIntermediateDirectories: intermediates
                )
            },
            contentsOfDirectory: { url in
                try FileManager.default.contentsOfDirectory(
                    at: url,
                    includingPropertiesForKeys: nil
                )
            },
            replaceItem: { _, _ in throw ReplaceFailed() },
            removeItem: { url in try FileManager.default.removeItem(at: url) }
        )
        let store = ProjectBundleStore(fileManager: wrapper)

        XCTAssertThrowsError(try store.writeProject(Project(name: "Fail"), to: bundle))

        let contents = try FileManager.default.contentsOfDirectory(
            at: bundle.url,
            includingPropertiesForKeys: nil
        )
        let leftoverTempFiles = contents.filter { $0.lastPathComponent.hasPrefix(".project.json.tmp-") }
        XCTAssertEqual(leftoverTempFiles, [],
                       "failed atomic write must remove the staged temp project file")
    }

    // MARK: - Refusing to overwrite

    func test_createBundle_refusesIfPathAlreadyExists() throws {
        let bundleURL = tempDirectory.appendingPathComponent("Existing.pixelbay")
        let store = ProjectBundleStore()
        _ = try store.createBundle(at: bundleURL, project: Project(name: "First"))

        XCTAssertThrowsError(try store.createBundle(at: bundleURL, project: Project(name: "Second"))) { error in
            guard case ProjectBundleError.bundleAlreadyExists = error else {
                return XCTFail("expected .bundleAlreadyExists, got \(error)")
            }
        }
    }

    func test_createBundle_initialWriteFailure_removesPartialBundle() throws {
        let bundleURL = tempDirectory.appendingPathComponent("Partial.pixelbay")

        struct ReplaceFailed: Error {}
        let wrapper = FileManagerWrapper(
            fileExists: { FileManager.default.fileExists(atPath: $0) },
            createDirectory: { url, intermediates in
                try FileManager.default.createDirectory(
                    at: url,
                    withIntermediateDirectories: intermediates
                )
            },
            contentsOfDirectory: { url in
                try FileManager.default.contentsOfDirectory(
                    at: url,
                    includingPropertiesForKeys: nil
                )
            },
            replaceItem: { _, _ in throw ReplaceFailed() },
            removeItem: { url in try FileManager.default.removeItem(at: url) }
        )
        let store = ProjectBundleStore(fileManager: wrapper)

        XCTAssertThrowsError(try store.createBundle(at: bundleURL, project: Project(name: "Partial")))
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: bundleURL.path),
            "failed bundle creation must not leave a partial .pixelbay package behind"
        )
    }

    // MARK: - Recovery scan

    func test_scan_findsMissingProjectJsonAsOrphaned() throws {
        let badBundle = tempDirectory.appendingPathComponent("Orphan.pixelbay")
        try FileManager.default.createDirectory(at: badBundle, withIntermediateDirectories: true)
        // Note: no project.json written -> qualifies as orphaned.

        let goodBundle = tempDirectory.appendingPathComponent("Healthy.pixelbay")
        let store = ProjectBundleStore()
        _ = try store.createBundle(at: goodBundle, project: Project(name: "Healthy"))

        let orphans = store.scanForOrphanedBundles(in: tempDirectory)
        XCTAssertTrue(orphans.contains(where: { $0.lastPathComponent == "Orphan.pixelbay" }))
        XCTAssertFalse(orphans.contains(where: { $0.lastPathComponent == "Healthy.pixelbay" }))
    }
}
