import Foundation

// On-disk layout of a `.pixelbay` package directory:
//
//   MyProject.pixelbay/
//     project.json          schemaVersion + bundleVersion at top
//     media/                captured + imported source files
//     thumbnails/           cached frame thumbnails for the timeline UI
//     voiceovers/           voiceover takes recorded inside the editor
//
// `LSTypeIsPackage = true` is set on the .pixelbay UTI in Info.plist so Finder
// shows the directory as an opaque file. The directory form (rather than a
// zip) means recordings can stream straight to disk during capture without
// any "save" step, and a crash mid-record leaves a recoverable bundle.

public struct ProjectBundle: Sendable {
    public let url: URL

    public static let pathExtension = "pixelbay"
    public static let projectFileName = "project.json"
    public static let mediaDirectoryName = "media"
    public static let thumbnailsDirectoryName = "thumbnails"
    public static let voiceoversDirectoryName = "voiceovers"

    public init(url: URL) {
        self.url = url
    }

    public var projectFileURL: URL { url.appendingPathComponent(Self.projectFileName) }
    public var mediaDirectoryURL: URL { url.appendingPathComponent(Self.mediaDirectoryName) }
    public var thumbnailsDirectoryURL: URL { url.appendingPathComponent(Self.thumbnailsDirectoryName) }
    public var voiceoversDirectoryURL: URL { url.appendingPathComponent(Self.voiceoversDirectoryName) }

    public func mediaURL(for asset: MediaAsset) -> URL {
        url.appendingPathComponent(asset.relativePath)
    }
}

public enum ProjectBundleError: Error, CustomStringConvertible {
    case bundleAlreadyExists(URL)
    case projectFileMissing(URL)
    case projectFileMalformed(underlying: Error)

    public var description: String {
        switch self {
        case .bundleAlreadyExists(let url):
            return "a Pixelbay project already exists at \(url.path)"
        case .projectFileMissing(let url):
            return "project.json not found at \(url.path)"
        case .projectFileMalformed(let underlying):
            return "project.json could not be decoded: \(underlying)"
        }
    }
}

public struct ProjectBundleStore: Sendable {
    public let migrationRegistry: MigrationRegistry
    public let fileManager: FileManagerWrapper

    public init(
        migrationRegistry: MigrationRegistry = .standard,
        fileManager: FileManagerWrapper = .default
    ) {
        self.migrationRegistry = migrationRegistry
        self.fileManager = fileManager
    }

    // Creates the .pixelbay directory and all standard subdirectories, then
    // writes an initial project.json. Returns the bundle ready for the capture
    // pipeline to stream media into. Throws if the path is already taken.
    public func createBundle(at url: URL, project: Project) throws -> ProjectBundle {
        let bundle = ProjectBundle(url: url)
        if fileManager.fileExists(url.path) {
            throw ProjectBundleError.bundleAlreadyExists(url)
        }
        var createdBundleRoot = false
        do {
            try fileManager.createDirectory(at: bundle.url, withIntermediateDirectories: true)
            createdBundleRoot = true
            try fileManager.createDirectory(at: bundle.mediaDirectoryURL, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: bundle.thumbnailsDirectoryURL, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: bundle.voiceoversDirectoryURL, withIntermediateDirectories: true)
            try writeProject(project, to: bundle)
        } catch {
            if createdBundleRoot {
                try? fileManager.removeItem(at: bundle.url)
            }
            throw error
        }
        return bundle
    }

    // Atomic save of project.json. Writes to a temp file in the same directory,
    // then renames over the existing file. A crash partway through leaves the
    // previous project.json intact rather than a half-written one.
    public func writeProject(_ project: Project, to bundle: ProjectBundle) throws {
        let encoder = Self.makeEncoder()
        var copy = project
        copy.modifiedAt = Date()
        let data = try encoder.encode(copy)

        let tempURL = bundle.url
            .appendingPathComponent(".project.json.tmp-\(UUID().uuidString)")
        try data.write(to: tempURL, options: .atomic)
        do {
            // _ = is sufficient on macOS; replaceItem swaps atomically.
            _ = try fileManager.replaceItem(
                at: bundle.projectFileURL,
                withItemAt: tempURL
            )
        } catch {
            try? fileManager.removeItem(at: tempURL)
            throw error
        }
    }

    // Reads project.json, runs migrators if the schemaVersion is older than
    // the current binary supports, then strict-decodes into Project.
    public func loadProject(from bundle: ProjectBundle) throws -> Project {
        guard fileManager.fileExists(bundle.projectFileURL.path) else {
            throw ProjectBundleError.projectFileMissing(bundle.projectFileURL)
        }
        let raw = try Data(contentsOf: bundle.projectFileURL)
        do {
            let json = try JSONSerialization.jsonObject(with: raw, options: [])
            guard let dict = json as? [String: Any] else {
                throw ProjectBundleError.projectFileMalformed(
                    underlying: NSError(
                        domain: "Pixelbay",
                        code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "project.json root is not an object"]
                    )
                )
            }
            let migrated = try migrationRegistry.migrate(dict)
            let migratedData = try JSONSerialization.data(withJSONObject: migrated, options: [.sortedKeys])
            return try Self.makeDecoder().decode(Project.self, from: migratedData)
        } catch let error as ProjectBundleError {
            throw error
        } catch {
            throw ProjectBundleError.projectFileMalformed(underlying: error)
        }
    }

    // Recovery scan: returns bundle URLs in `searchDirectory` whose project.json
    // is missing, malformed, or marks the recording as in-progress. Phase 1
    // surfaces these on next launch as "Recover unfinished recording?" prompts.
    public func scanForOrphanedBundles(in searchDirectory: URL) -> [URL] {
        guard let contents = try? fileManager.contentsOfDirectory(at: searchDirectory) else {
            return []
        }
        return contents
            .filter { $0.pathExtension == ProjectBundle.pathExtension }
            .filter { url in
                let projectFile = url.appendingPathComponent(ProjectBundle.projectFileName)
                if !fileManager.fileExists(projectFile.path) { return true }
                guard let data = try? Data(contentsOf: projectFile),
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                else {
                    return true
                }
                if let inProgress = obj["recordingInProgress"] as? Bool, inProgress {
                    return true
                }
                return false
            }
    }

    private static func makeEncoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }

    private static func makeDecoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}

// FileManager methods we use are not Sendable in Swift 6 strict-concurrency
// land; this thin wrapper makes the touched surface area Sendable so the
// store can be passed across actors safely. Default impl forwards to
// FileManager.default but tests can substitute an in-memory mock.
public struct FileManagerWrapper: Sendable {
    public var fileExists: @Sendable (_ atPath: String) -> Bool
    public var createDirectory: @Sendable (_ at: URL, _ withIntermediateDirectories: Bool) throws -> Void
    public var contentsOfDirectory: @Sendable (_ at: URL) throws -> [URL]
    public var replaceItem: @Sendable (_ at: URL, _ withItemAt: URL) throws -> URL?
    public var removeItem: @Sendable (_ at: URL) throws -> Void

    public init(
        fileExists: @escaping @Sendable (String) -> Bool,
        createDirectory: @escaping @Sendable (URL, Bool) throws -> Void,
        contentsOfDirectory: @escaping @Sendable (URL) throws -> [URL],
        replaceItem: @escaping @Sendable (URL, URL) throws -> URL?,
        removeItem: @escaping @Sendable (URL) throws -> Void
    ) {
        self.fileExists = fileExists
        self.createDirectory = createDirectory
        self.contentsOfDirectory = contentsOfDirectory
        self.replaceItem = replaceItem
        self.removeItem = removeItem
    }

    public func createDirectory(at url: URL, withIntermediateDirectories: Bool) throws {
        try createDirectory(url, withIntermediateDirectories)
    }

    public func contentsOfDirectory(at url: URL) throws -> [URL] {
        try contentsOfDirectory(url)
    }

    public func replaceItem(at url: URL, withItemAt temp: URL) throws -> URL? {
        try replaceItem(url, temp)
    }

    public func removeItem(at url: URL) throws {
        try removeItem(url)
    }

    public static let `default` = FileManagerWrapper(
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
        replaceItem: { destination, temp in
            try FileManager.default.replaceItemAt(destination, withItemAt: temp)
        },
        removeItem: { url in
            try FileManager.default.removeItem(at: url)
        }
    )
}
