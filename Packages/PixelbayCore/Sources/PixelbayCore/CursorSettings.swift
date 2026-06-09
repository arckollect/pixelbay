import Foundation

// Project-wide synthetic cursor settings. Schema v4 (Phase 3c).
//
// When a screen recording is captured with `SCStreamConfiguration.showsCursor =
// false`, the compositor draws its own cursor sprite on top of the screen
// layer using the recorded `MouseTrajectorySample` stream. This struct holds
// the user-facing knobs that control that pass — currently just size. Color,
// click-press animation, and cursor-shape tracking are reserved for v2.
//
// The default `scale = 3.25` chosen so the cursor reads clearly when the
// recording is viewed at typical screencast sizes (half-window playback,
// embedded video). 1.75× tested too small — viewers reported losing the
// cursor on busy UI. 3.25× yields ~104 px on 1080p, matching the rough
// scale Screen Studio defaults to.

public struct CursorSettings: Codable, Sendable, Equatable {
    /// Master switch. When false the compositor skips the synthetic cursor
    /// pass even if the asset was captured with `showsCursor = false` —
    /// useful for users who want the raw OS cursor back on per-project basis.
    public var isEnabled: Bool

    /// Multiplier applied to the cursor sprite's intrinsic point size.
    /// 1.0 = native, 2.0 = double-size, etc. Clamped to a reasonable range
    /// by the inspector slider (0.5…4.0) but stored unclamped so future
    /// versions can widen the range without a migration.
    public var scale: Double

    public var extras: [String: JSONValue]

    public init(
        isEnabled: Bool = true,
        scale: Double = 3.25,
        extras: [String: JSONValue] = [:]
    ) {
        self.isEnabled = isEnabled
        self.scale = scale
        self.extras = extras
    }

    /// What the v3→v4 migrator stamps onto old projects (and what `Project`'s
    /// default initializer uses for fresh projects).
    public static let `default` = CursorSettings(isEnabled: true, scale: 3.25)

    private enum CodingKeys: String, CodingKey {
        case isEnabled
        case scale
        case extras
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.isEnabled = try c.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        self.scale = try c.decodeIfPresent(Double.self, forKey: .scale) ?? 3.25
        self.extras = try c.decodeIfPresent([String: JSONValue].self, forKey: .extras) ?? [:]
    }
}

// MARK: - MediaAsset extras key

extension MediaAsset {
    /// True iff this asset's screen recording was captured with the OS cursor
    /// suppressed (`SCStreamConfiguration.showsCursor = false`). The
    /// compositor only renders the synthetic cursor when this is set, so
    /// legacy projects (cursor baked into the screen frame) don't get a
    /// double cursor when opened in a v4+ build.
    ///
    /// Stored in `extras` rather than as a top-level field so it can ship
    /// without a `MediaAsset` schema migration; new captures stamp it,
    /// older recordings keep their old behavior.
    public var cursorRenderedSynthetically: Bool {
        get {
            if case .bool(let b) = extras["cursorRenderedSynthetically"] { return b }
            return false
        }
        set {
            extras["cursorRenderedSynthetically"] = .bool(newValue)
        }
    }
}
