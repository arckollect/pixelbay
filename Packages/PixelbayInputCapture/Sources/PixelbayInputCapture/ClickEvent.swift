import Foundation

// Single mouse-down observed by the click logger. Phase 1 only writes
// .leftMouseDown and .rightMouseDown — keystroke logging is Phase 4 and
// rides on a different code path (per HANDOFF §6.7 + §2.6).
//
// Timestamps are in host-clock seconds, matching the domain used by
// SCStream / AVCaptureSession for sample buffer PTS (HANDOFF §6.5). The
// editor aligns these against `MediaAsset.captureStart` at edit time —
// the capture pipeline does NOT do click lookahead at capture time, that
// can't work because the click hasn't happened yet (HANDOFF §2.6).
//
// `x` / `y` coordinate space depends on the parent `ClicksSidecar.version`:
//   * v1 / v2: raw global-screen points from `CGEvent.location`. Editor must
//     normalise by the recording's pixel size (the legacy AutoZoomService
//     path — wrong on Retina because points ≠ pixels, but preserved for
//     pre-2026-05-13 sidecars).
//   * v3+: already normalised to `[0…1]` against the recorded display's
//     points size at write time. Editor consumes them directly.
public struct ClickEvent: Codable, Sendable, Equatable {
    public enum Button: String, Codable, Sendable, Equatable {
        case left
        case right
    }

    public var timestamp: Double
    public var x: Double
    public var y: Double
    public var button: Button

    public init(timestamp: Double, x: Double, y: Double, button: Button) {
        self.timestamp = timestamp
        self.x = x
        self.y = y
        self.button = button
    }
}

// Mouse-position sample (no button state). Used by Phase 3b mouse-tracking
// auto-zoom so a zoom segment can "follow the cursor" instead of holding
// one fixed centre. Host-clock timestamps mirror `ClickEvent.timestamp`.
public struct MouseMove: Codable, Sendable, Equatable {
    public var timestamp: Double
    public var x: Double
    public var y: Double

    public init(timestamp: Double, x: Double, y: Double) {
        self.timestamp = timestamp
        self.x = x
        self.y = y
    }
}

// User-stated zoom anchor logged by pressing the "Mark Zoom Point" global
// hotkey during a recording session. Shape mirrors `MouseMove` because the
// editor treats marks as user-supplied AutoZoomClicks (no clustering, no
// filtering — the user said "zoom here"). Schema-versioned via the parent
// `ClicksSidecar.version` (v4+).
public struct ZoomMark: Codable, Sendable, Equatable {
    public var timestamp: Double
    public var x: Double
    public var y: Double

    public init(timestamp: Double, x: Double, y: Double) {
        self.timestamp = timestamp
        self.x = x
        self.y = y
    }
}

// On-disk shape of `media/clicks-<sessionID>.json`. Kept as a versioned
// struct so future fields (modifier flags, click type, scroll deltas) can
// be added without breaking the v0.1 reader.
//
// v2 (2026-05-13) added `moves: [MouseMove]` for the Phase 3b mouse-tracking
// trajectory. v1 files decode with `moves == []` thanks to the custom
// `init(from:)` that tolerates the missing key.
//
// v3 (2026-05-13) changed coordinate semantics: x/y on every `events` and
// `moves` entry are written in normalised `[0…1]` space against the
// recorded display's points size (not pixels). v1/v2 wrote raw global
// points from `CGEvent.location` and the editor divided by the recording's
// pixel size — which mismatched on Retina (points ≠ pixels) and made the
// auto-zoom anchor lag behind the cursor / clamp to a screen edge. v3
// pushes the normalisation into the writer where it has the points size
// (`SCDisplay.width / height`).
//
// v4 (2026-05-14) added `marks: [ZoomMark]` for user-stated zoom anchors
// (the "Mark Zoom Point" hotkey, slice #11.d). v1-v3 files decode with
// `marks == []` thanks to the `decodeIfPresent` clause.
public struct ClicksSidecar: Codable, Sendable, Equatable {
    public static let currentVersion: Int = 4

    public var version: Int
    public var sessionID: String
    /// Host-clock seconds at the recording's first-sample time. The editor
    /// subtracts this from each event's `timestamp` to get the offset into
    /// the timeline. Mirrors `CaptureSummary.captureStart`.
    public var captureStart: Double
    public var events: [ClickEvent]
    public var moves: [MouseMove]
    public var marks: [ZoomMark]

    public init(
        version: Int = ClicksSidecar.currentVersion,
        sessionID: String,
        captureStart: Double,
        events: [ClickEvent],
        moves: [MouseMove] = [],
        marks: [ZoomMark] = []
    ) {
        self.version = version
        self.sessionID = sessionID
        self.captureStart = captureStart
        self.events = events
        self.moves = moves
        self.marks = marks
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case sessionID
        case captureStart
        case events
        case moves
        case marks
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.version = try container.decode(Int.self, forKey: .version)
        self.sessionID = try container.decode(String.self, forKey: .sessionID)
        self.captureStart = try container.decode(Double.self, forKey: .captureStart)
        self.events = try container.decode([ClickEvent].self, forKey: .events)
        self.moves = try container.decodeIfPresent([MouseMove].self, forKey: .moves) ?? []
        self.marks = try container.decodeIfPresent([ZoomMark].self, forKey: .marks) ?? []
    }
}
