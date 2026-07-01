import Foundation

// Bumped on any breaking change to project.json. A Migrator must be registered
// for every adjacent version pair (n -> n+1) in MigrationRegistry.
//
// v1 → v2 (Phase 3a, 2026-05-12): adds `layout: LayoutPreset` to Project for
// cam position / cam shape / background. Migrator fills the default that
// preserves Phase 1 behavior (bottom-right PiP, 12pt rounded rectangle, no
// background). See `LayoutPreset.phase1Default`.
//
// v2 → v3 (Phase 3b, 2026-05-12): adds `effects: [EffectKeyframe]` to
// Project — time-ranged auto-zoom / talking-head swap segments rendered by
// the compositor on top of the base layout. Empty array preserves prior
// visual output. See `EffectKeyframe`.
//
// v3 → v4 (Phase 3c, 2026-05-14): adds `cursorSettings: CursorSettings` to
// Project. The screen capture path stops baking the OS cursor into recorded
// frames (`SCStreamConfiguration.showsCursor = false`) and the compositor
// draws a synthetic cursor sprite at a user-adjustable scale on top of the
// screen layer using the existing mouse-trajectory sidecar. The migrator
// stamps `CursorSettings.default` on old projects; legacy assets still have
// their OS cursor baked in, so the compositor only renders synthetic cursor
// when the screen `MediaAsset.cursorRenderedSynthetically` flag is set
// (stored in `extras`, no MediaAsset schema bump needed).
//
// v4 → v5 (Phase 5 — Scenes, 2026-05-26): adds optional `scenesSession:
// ScenesSession?` to Project. Non-nil means the project is the persistent
// .pixelbay bundle backing the Scenes window (multi-take recording, merge
// produces a normal timeline-editable project and clears the field back to
// nil). The migrator is a no-op because the field is optional — pre-v5
// projects decode cleanly with `scenesSession == nil`.
//
// v6 → v7 (2026-06-12): adds `fastMotionSensitivity` and `edgeCushion` to
// `TuningSettings`, widens camera ranges, and changes the default motion feel
// to a slower hybrid zoom-follow.
//
// v7 → v8 (2026-06-17): adds the `LayoutMode.custom(screen:webcam:)` case for
// free-form drag/scale layouts (`NormalizedRect` per layer). A new enum case
// is not forward-compatible — an older Pixelbay can't decode `.custom` — so we
// bump the version (unlike a purely additive optional field). The migrator is
// a no-op: existing projects only ever encode `.pip`/`.splitHorizontal`, which
// decode unchanged under the v8 model. Bumping makes older builds reject a
// `.custom` project with the clean "upgrade Pixelbay" error rather than a raw
// decode failure.
public let currentSchemaVersion: Int = 8

// Bumped on any breaking change to the .pixelbay directory layout itself
// (e.g. renaming the media/ folder, splitting sidecars into a new subdirectory).
// Tracked separately because directory restructures are harder to migrate than JSON edits.
public let currentBundleVersion: Int = 1

public struct ProjectID: Hashable, Codable, Sendable, RawRepresentable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static func generate() -> ProjectID { ProjectID(rawValue: UUID().uuidString) }
}

public struct TrackID: Hashable, Codable, Sendable, RawRepresentable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static func generate() -> TrackID { TrackID(rawValue: UUID().uuidString) }
}

public struct ClipID: Hashable, Codable, Sendable, RawRepresentable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static func generate() -> ClipID { ClipID(rawValue: UUID().uuidString) }
}

public struct MediaAssetID: Hashable, Codable, Sendable, RawRepresentable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static func generate() -> MediaAssetID { MediaAssetID(rawValue: UUID().uuidString) }
}

// Time is stored as rational (numerator/denominator) seconds so we can round-trip
// to/from CMTime without floating-point drift. Editor invariants depend on exact equality.
public struct RationalTime: Hashable, Codable, Sendable {
    public let value: Int64
    public let timescale: Int32

    public init(value: Int64, timescale: Int32) {
        self.value = value
        self.timescale = timescale
    }

    public static let zero = RationalTime(value: 0, timescale: 600)

    public var seconds: Double { Double(value) / Double(timescale) }

    public static func seconds(_ s: Double, timescale: Int32 = 600) -> RationalTime {
        RationalTime(value: Int64((s * Double(timescale)).rounded()), timescale: timescale)
    }

    private enum CodingKeys: String, CodingKey {
        case value
        case timescale
    }
}

public struct TimeRange: Hashable, Codable, Sendable {
    public let start: RationalTime
    public let duration: RationalTime

    public init(start: RationalTime, duration: RationalTime) {
        self.start = start
        self.duration = duration
    }

    public var end: RationalTime {
        // Both rationals are normalized at write time elsewhere; for end we just
        // assume matching timescales (true for everything we generate).
        precondition(start.timescale == duration.timescale,
                     "Mixed timescales not supported in TimeRange.end")
        return RationalTime(value: start.value + duration.value, timescale: start.timescale)
    }

    /// Half-open overlap test. Two ranges overlap iff each one starts before
    /// the other ends. Adjacent ranges (`a.end == b.start`) are NOT
    /// overlapping — matches `EffectKeyframe.strength(at:)` which returns 0
    /// at the keyframe's `end` time (the half-open `[start, end)` interval),
    /// so a fresh keyframe can pick up exactly when the previous one expires.
    public func overlaps(_ other: TimeRange) -> Bool {
        start.seconds < other.end.seconds
            && other.start.seconds < end.seconds
    }

    private enum CodingKeys: String, CodingKey {
        case start
        case duration
    }
}

public enum CaptureSourceKind: String, Codable, Sendable {
    case display
    case window
    case area
    case device      // Continuity Camera / external capture device
    case webcam
    case microphone
    case systemAudio
    case voiceover   // recorded inside the editor
    case imported    // user-imported file
}

public struct MediaAsset: Codable, Sendable, Identifiable {
    public let id: MediaAssetID
    public var kind: CaptureSourceKind
    // Path relative to the project bundle root, e.g. "media/screen-2026-05-01-001.mov".
    // Storing relative paths keeps projects portable across machines.
    public var relativePath: String
    // Absolute time (seconds since recording session epoch) when this asset began,
    // so multiple parallel recordings can be aligned in the editor.
    public var captureStart: RationalTime?
    public var nativeDuration: RationalTime
    public var extras: [String: JSONValue]

    public init(
        id: MediaAssetID = .generate(),
        kind: CaptureSourceKind,
        relativePath: String,
        captureStart: RationalTime? = nil,
        nativeDuration: RationalTime,
        extras: [String: JSONValue] = [:]
    ) {
        self.id = id
        self.kind = kind
        self.relativePath = relativePath
        self.captureStart = captureStart
        self.nativeDuration = nativeDuration
        self.extras = extras
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case kind
        case relativePath
        case captureStart
        case nativeDuration
        case extras
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(MediaAssetID.self, forKey: .id)
        self.kind = try c.decode(CaptureSourceKind.self, forKey: .kind)
        self.relativePath = try c.decode(String.self, forKey: .relativePath)
        self.captureStart = try c.decodeIfPresent(RationalTime.self, forKey: .captureStart)
        self.nativeDuration = try c.decode(RationalTime.self, forKey: .nativeDuration)
        self.extras = try c.decodeIfPresent([String: JSONValue].self, forKey: .extras) ?? [:]
    }
}

// A clip is a non-destructive slice into a MediaAsset.
//
// sourceRange  = which part of the underlying file this clip refers to
// timelineRange = where this clip sits in the project timeline
//
// Trimming the in-point shrinks sourceRange.start; dragging the edge back out
// later expands sourceRange.start, recovering material that was previously
// trimmed. The underlying file is never modified.
public struct Clip: Codable, Sendable, Identifiable, Equatable {
    public let id: ClipID
    public var assetID: MediaAssetID
    public var sourceRange: TimeRange
    public var timelineRange: TimeRange
    public var volume: Double            // 0.0...1.0+ (Phase 2)
    public var speed: Double             // 1.0 = realtime (Phase 2)
    public var enabled: Bool
    public var extras: [String: JSONValue]

    public init(
        id: ClipID = .generate(),
        assetID: MediaAssetID,
        sourceRange: TimeRange,
        timelineRange: TimeRange,
        volume: Double = 1.0,
        speed: Double = 1.0,
        enabled: Bool = true,
        extras: [String: JSONValue] = [:]
    ) {
        self.id = id
        self.assetID = assetID
        self.sourceRange = sourceRange
        self.timelineRange = timelineRange
        self.volume = volume
        self.speed = speed
        self.enabled = enabled
        self.extras = extras
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case assetID
        case sourceRange
        case timelineRange
        case volume
        case speed
        case enabled
        case extras
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(ClipID.self, forKey: .id)
        self.assetID = try c.decode(MediaAssetID.self, forKey: .assetID)
        self.sourceRange = try c.decode(TimeRange.self, forKey: .sourceRange)
        self.timelineRange = try c.decode(TimeRange.self, forKey: .timelineRange)
        self.volume = try c.decodeIfPresent(Double.self, forKey: .volume) ?? 1.0
        self.speed = try c.decodeIfPresent(Double.self, forKey: .speed) ?? 1.0
        self.enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        self.extras = try c.decodeIfPresent([String: JSONValue].self, forKey: .extras) ?? [:]
    }
}

public enum TrackKind: String, Codable, Sendable {
    case screen
    case webcam
    case microphone
    case systemAudio
    case voiceover
    case overlay     // text, images
    case effects     // zoom keyframes, blur masks (Phase 3)
}

// Tracks are independent from day 1 in the schema even though Phase 1 always
// presents them as a grouped recording. Phase 2 exposes ungrouping in the UI
// without a schema migration.
public struct Track: Codable, Sendable, Identifiable, Equatable {
    public let id: TrackID
    public var kind: TrackKind
    public var name: String
    public var clips: [Clip]
    public var muted: Bool
    public var hidden: Bool
    public var extras: [String: JSONValue]

    public init(
        id: TrackID = .generate(),
        kind: TrackKind,
        name: String,
        clips: [Clip] = [],
        muted: Bool = false,
        hidden: Bool = false,
        extras: [String: JSONValue] = [:]
    ) {
        self.id = id
        self.kind = kind
        self.name = name
        self.clips = clips
        self.muted = muted
        self.hidden = hidden
        self.extras = extras
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case kind
        case name
        case clips
        case muted
        case hidden
        case extras
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(TrackID.self, forKey: .id)
        self.kind = try c.decode(TrackKind.self, forKey: .kind)
        self.name = try c.decode(String.self, forKey: .name)
        self.clips = try c.decode([Clip].self, forKey: .clips)
        self.muted = try c.decodeIfPresent(Bool.self, forKey: .muted) ?? false
        self.hidden = try c.decodeIfPresent(Bool.self, forKey: .hidden) ?? false
        self.extras = try c.decodeIfPresent([String: JSONValue].self, forKey: .extras) ?? [:]
    }
}

// Represents which screen-recording asset is "active" at a given timeline
// position. Phase 1 always has a single entry; Phase 4's mid-recording
// window-swap creates multiple entries pointing at parallel SCStream files.
public struct SourceSegment: Codable, Sendable {
    public var assetID: MediaAssetID
    public var timelineRange: TimeRange
    public var extras: [String: JSONValue]

    public init(
        assetID: MediaAssetID,
        timelineRange: TimeRange,
        extras: [String: JSONValue] = [:]
    ) {
        self.assetID = assetID
        self.timelineRange = timelineRange
        self.extras = extras
    }

    private enum CodingKeys: String, CodingKey {
        case assetID
        case timelineRange
        case extras
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.assetID = try c.decode(MediaAssetID.self, forKey: .assetID)
        self.timelineRange = try c.decode(TimeRange.self, forKey: .timelineRange)
        self.extras = try c.decodeIfPresent([String: JSONValue].self, forKey: .extras) ?? [:]
    }
}

public struct Project: Codable, Sendable, Identifiable {
    public var schemaVersion: Int
    public var bundleVersion: Int
    public let id: ProjectID
    public var name: String
    public var createdAt: Date
    public var modifiedAt: Date
    public var assets: [MediaAsset]
    public var tracks: [Track]
    // Active source-segment timeline: drives which screen recording is on screen
    // when at a given playhead position. Empty in pure-import projects.
    public var sourceSegments: [SourceSegment]
    // Phase 3a — controls cam position / shape, background, and screen padding.
    // Migrated in from v1 with `LayoutPreset.phase1Default` (preserves the old
    // "bottom-right PiP, 12pt rounded rectangle, no background" look).
    public var layout: LayoutPreset
    // Phase 3b — auto-zoom + talking-head swap keyframes. Empty array =
    // legacy compositing (base layout only, no per-frame effects).
    public var effects: [EffectKeyframe]
    // v6 — project-wide motion tuning: camera-follow feel, cursor-path
    // smoothing, and motion blur. The single authority for motion params;
    // nothing downstream resolves or overwrites these. Replaces the retired
    // `zoomFollowStyle` macro sliders (the v5→v6 migrator drops that key).
    public var tuning: TuningSettings
    // Phase 3c — synthetic cursor settings (size, zoom boost, on/off).
    // Defaults preserve the current synthetic-cursor behavior for fresh
    // projects; the v3→v4 migrator stamps the same default onto old projects
    // and the compositor gates on per-asset `cursorRenderedSynthetically` so
    // legacy recordings (cursor baked into screen frames) skip the synthetic
    // pass and avoid a double cursor.
    public var cursorSettings: CursorSettings
    // Phase 5 — populated only on the persistent scenes-session bundle. `nil`
    // for every "normal" project (whether brand-new, imported, or the result
    // of a Scenes-mode merge). The Codable optional-decode contract treats a
    // missing JSON key as `nil`, so pre-v5 documents continue to decode
    // without any data stamping (the v4→v5 migrator is a no-op).
    public var scenesSession: ScenesSession?
    public var extras: [String: JSONValue]

    public init(
        schemaVersion: Int = currentSchemaVersion,
        bundleVersion: Int = currentBundleVersion,
        id: ProjectID = .generate(),
        name: String,
        createdAt: Date = Date(),
        modifiedAt: Date = Date(),
        assets: [MediaAsset] = [],
        tracks: [Track] = [],
        sourceSegments: [SourceSegment] = [],
        layout: LayoutPreset = .phase1Default,
        effects: [EffectKeyframe] = [],
        tuning: TuningSettings = .default,
        cursorSettings: CursorSettings = .default,
        scenesSession: ScenesSession? = nil,
        extras: [String: JSONValue] = [:]
    ) {
        self.schemaVersion = schemaVersion
        self.bundleVersion = bundleVersion
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
        self.assets = assets
        self.tracks = tracks
        self.sourceSegments = sourceSegments
        self.layout = layout
        self.effects = effects
        self.tuning = tuning
        self.cursorSettings = cursorSettings
        self.scenesSession = scenesSession
        self.extras = extras
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case bundleVersion
        case id
        case name
        case createdAt
        case modifiedAt
        case assets
        case tracks
        case sourceSegments
        case layout
        case effects
        case tuning
        case cursorSettings
        case scenesSession
        case extras
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.schemaVersion = try c.decode(Int.self, forKey: .schemaVersion)
        self.bundleVersion = try c.decodeIfPresent(Int.self, forKey: .bundleVersion) ?? currentBundleVersion
        self.id = try c.decode(ProjectID.self, forKey: .id)
        self.name = try c.decode(String.self, forKey: .name)
        self.createdAt = try c.decode(Date.self, forKey: .createdAt)
        self.modifiedAt = try c.decode(Date.self, forKey: .modifiedAt)
        self.assets = try c.decodeIfPresent([MediaAsset].self, forKey: .assets) ?? []
        self.tracks = try c.decodeIfPresent([Track].self, forKey: .tracks) ?? []
        self.sourceSegments = try c.decodeIfPresent([SourceSegment].self, forKey: .sourceSegments) ?? []
        self.layout = try c.decodeIfPresent(LayoutPreset.self, forKey: .layout) ?? .phase1Default
        self.effects = try c.decodeIfPresent([EffectKeyframe].self, forKey: .effects) ?? []
        self.tuning = try c.decodeIfPresent(TuningSettings.self, forKey: .tuning) ?? .default
        self.cursorSettings = try c.decodeIfPresent(CursorSettings.self, forKey: .cursorSettings) ?? .default
        self.scenesSession = try c.decodeIfPresent(ScenesSession.self, forKey: .scenesSession)
        self.extras = try c.decodeIfPresent([String: JSONValue].self, forKey: .extras) ?? [:]
    }
}
