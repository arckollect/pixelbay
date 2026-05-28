import Foundation

// Phase 5 — Scenes (Multi-Take Scene-Based Recording).
//
// A ScenesSession is the model behind the dedicated Scenes window. Each Scene
// is a planned segment of a multi-take recording project (intro / demo / outro,
// or a 5-scene tutorial). The user can re-record a Scene multiple times — each
// recording becomes a Take, all stored inside the same persistent .pixelbay
// bundle. The user picks one Take per Scene as active; on Merge those active
// Takes get stitched back-to-back onto shared screen/webcam/mic/sysAudio tracks
// (one Track per relevant TrackKind), producing a normal timeline-editable
// Pixelbay project (`Project.scenesSession` cleared after merge).
//
// Stored as `Project.scenesSession: ScenesSession?` (schema v5). `nil` means
// the project has been merged (or was never a scenes project to begin with).
//
// Lives in PixelbayCore because the Project schema needs it; the orchestration
// model (live recording, persistence, bundle archive) lives in the app target.

public struct SceneID: Hashable, Codable, Sendable, RawRepresentable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static func generate() -> SceneID { SceneID(rawValue: UUID().uuidString) }
}

public struct TakeID: Hashable, Codable, Sendable, RawRepresentable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static func generate() -> TakeID { TakeID(rawValue: UUID().uuidString) }
}

/// One recording attempt for a Scene. Multiple takes per scene are kept around
/// (per decision #9) until a user-triggered "Clean up unused takes" command
/// prunes the orphaned ones — so the user can swap which take is active without
/// having to re-record.
public struct Take: Codable, Sendable, Identifiable, Equatable {
    public let id: TakeID
    public let recordedAt: Date
    /// 8-char session prefix from `CaptureOutputDeriver`; matches what
    /// `screen-{sessionID}.mov` / `clicks-{sessionID}.json` etc. use.
    public let sessionID: String
    /// All MediaAssetIDs produced by this take (screen + webcam + mic + sysAudio).
    /// These are pointers into `Project.assets` — assets live in the shared
    /// project asset list so the merge step can build Clips against them
    /// without re-importing.
    public var assetIDs: [MediaAssetID]
    /// Cached so the UI doesn't need to re-read media files to display
    /// take length on the scene row.
    public var durationSeconds: Double
    /// Path relative to the project bundle root, e.g.
    /// "media/thumb-{sessionID}.png". `nil` until thumbnail extraction
    /// completes (slice 5.6).
    public var thumbnailRelativePath: String?
    public var extras: [String: JSONValue]

    public init(
        id: TakeID = .generate(),
        recordedAt: Date = Date(),
        sessionID: String,
        assetIDs: [MediaAssetID] = [],
        durationSeconds: Double = 0,
        thumbnailRelativePath: String? = nil,
        extras: [String: JSONValue] = [:]
    ) {
        self.id = id
        self.recordedAt = recordedAt
        self.sessionID = sessionID
        self.assetIDs = assetIDs
        self.durationSeconds = durationSeconds
        self.thumbnailRelativePath = thumbnailRelativePath
        self.extras = extras
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case recordedAt
        case sessionID
        case assetIDs
        case durationSeconds
        case thumbnailRelativePath
        case extras
    }
}

/// Per-scene source-config overrides. Any field that's non-nil wins over the
/// corresponding `ScenesGlobalDefaults` field on the parent session. All-nil
/// (`hasAnyOverride == false`) means the scene uses the global defaults verbatim.
public struct SceneSourceOverride: Codable, Sendable, Equatable {
    public var displayID: UInt32?          // CGDirectDisplayID
    public var cameraUniqueID: String?
    public var micUniqueID: String?
    public var includeSystemAudio: Bool?

    public init(
        displayID: UInt32? = nil,
        cameraUniqueID: String? = nil,
        micUniqueID: String? = nil,
        includeSystemAudio: Bool? = nil
    ) {
        self.displayID = displayID
        self.cameraUniqueID = cameraUniqueID
        self.micUniqueID = micUniqueID
        self.includeSystemAudio = includeSystemAudio
    }

    public var hasAnyOverride: Bool {
        displayID != nil
            || cameraUniqueID != nil
            || micUniqueID != nil
            || includeSystemAudio != nil
    }

    private enum CodingKeys: String, CodingKey {
        case displayID
        case cameraUniqueID
        case micUniqueID
        case includeSystemAudio
    }
}

/// A planned recording segment. Holds zero or more Takes; the user picks
/// which Take is currently "active" via `activeTakeIndex`.
public struct Scene: Codable, Sendable, Identifiable, Equatable {
    public let id: SceneID
    /// Optional free-text description. After merge this is stamped onto the
    /// produced Clip's `extras["sceneDescription"]`.
    public var description: String
    public var sourceOverride: SceneSourceOverride
    /// Ordered list of takes (recording 1, recording 2, …). Re-recording the
    /// scene appends; nothing is replaced. Decision #3.
    public var takes: [Take]
    /// Which take in `takes` is the active one (merged into the final project).
    /// `nil` until the first recording lands. When `nil`, the scene is "empty"
    /// and the merge step skips it.
    public var activeTakeIndex: Int?
    public var extras: [String: JSONValue]

    public init(
        id: SceneID = .generate(),
        description: String = "",
        sourceOverride: SceneSourceOverride = SceneSourceOverride(),
        takes: [Take] = [],
        activeTakeIndex: Int? = nil,
        extras: [String: JSONValue] = [:]
    ) {
        self.id = id
        self.description = description
        self.sourceOverride = sourceOverride
        self.takes = takes
        self.activeTakeIndex = activeTakeIndex
        self.extras = extras
    }

    /// Convenience accessor for the active take. Returns `nil` when there are
    /// no takes yet OR when `activeTakeIndex` is somehow out of bounds (a
    /// state we never write but defensively tolerate on decode).
    public var activeTake: Take? {
        guard let idx = activeTakeIndex,
              takes.indices.contains(idx)
        else { return nil }
        return takes[idx]
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case description
        case sourceOverride
        case takes
        case activeTakeIndex
        case extras
    }
}

/// Top-of-scenes-window pickers: the defaults every scene inherits unless its
/// `sourceOverride` overrides a given field.
public struct ScenesGlobalDefaults: Codable, Sendable, Equatable {
    public var displayID: UInt32?
    public var cameraUniqueID: String?
    public var micUniqueID: String?
    public var includeSystemAudio: Bool
    public var logClicks: Bool

    public init(
        displayID: UInt32? = nil,
        cameraUniqueID: String? = nil,
        micUniqueID: String? = nil,
        includeSystemAudio: Bool = false,
        logClicks: Bool = true
    ) {
        self.displayID = displayID
        self.cameraUniqueID = cameraUniqueID
        self.micUniqueID = micUniqueID
        self.includeSystemAudio = includeSystemAudio
        self.logClicks = logClicks
    }

    private enum CodingKeys: String, CodingKey {
        case displayID
        case cameraUniqueID
        case micUniqueID
        case includeSystemAudio
        case logClicks
    }
}

/// The session state held inside `Project.scenesSession?`. The orchestration
/// model in the app target mirrors this in memory and writes it back through
/// `Project` on every change (debounced).
public struct ScenesSession: Codable, Sendable {
    public var defaults: ScenesGlobalDefaults
    public var scenes: [Scene]
    public var createdAt: Date
    public var modifiedAt: Date
    public var extras: [String: JSONValue]

    public init(
        defaults: ScenesGlobalDefaults = ScenesGlobalDefaults(),
        scenes: [Scene] = [],
        createdAt: Date = Date(),
        modifiedAt: Date = Date(),
        extras: [String: JSONValue] = [:]
    ) {
        self.defaults = defaults
        self.scenes = scenes
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
        self.extras = extras
    }

    /// Decision #12 — fresh scenes session starts with 3 empty rows.
    public static func freshDefault(now: Date = Date()) -> ScenesSession {
        ScenesSession(
            defaults: ScenesGlobalDefaults(),
            scenes: [Scene(), Scene(), Scene()],
            createdAt: now,
            modifiedAt: now
        )
    }

    private enum CodingKeys: String, CodingKey {
        case defaults
        case scenes
        case createdAt
        case modifiedAt
        case extras
    }
}
