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
    public static let defaultScale: Double = 3.25
    public static let defaultZoomScaleBoostPerZoomUnit: Double = 0.75
    public static let defaultVelocityScaleBoost: Double = 0.12
    public static let defaultVelocityScaleLow: Double = 0.15
    public static let defaultVelocityScaleHigh: Double = 1.20
    public static let defaultBlurSpeedLow: Double = 0.35
    public static let defaultBlurSpeedHigh: Double = 2.40
    public static let defaultBlurShutterMin: Double = 1.0 / 110.0
    public static let defaultBlurShutterMax: Double = 1.0 / 34.0
    public static let defaultBlurMaxUV: Double = 1.00

    public static let scaleRange: ClosedRange<Double> = 0.5...4.0
    public static let zoomScaleBoostPerZoomUnitRange: ClosedRange<Double> = 0.0...1.5
    public static let velocityScaleBoostRange: ClosedRange<Double> = 0.0...0.5
    public static let velocityScaleLowRange: ClosedRange<Double> = 0.0...2.0
    public static let velocityScaleHighRange: ClosedRange<Double> = 0.05...4.0
    public static let blurSpeedLowRange: ClosedRange<Double> = 0.0...3.0
    public static let blurSpeedHighRange: ClosedRange<Double> = 0.05...6.0
    public static let blurShutterMinRange: ClosedRange<Double> = (1.0 / 240.0)...(1.0 / 24.0)
    public static let blurShutterMaxRange: ClosedRange<Double> = (1.0 / 240.0)...(1.0 / 12.0)
    public static let blurMaxUVRange: ClosedRange<Double> = 0.05...2.0
    // Path-smoothing knobs retired 2026-06: the cursor sprite now renders
    // from the shared click-pinned smoothed path driven by
    // `TuningSettings.pathWindowSeconds` / `travelCollapse` /
    // `clickSnapWindow`. Old `pathSmoothing*` extras keys decode as inert
    // data.

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
        scale: Double = CursorSettings.defaultScale,
        extras: [String: JSONValue] = [:]
    ) {
        self.isEnabled = isEnabled
        self.scale = scale
        self.extras = extras
    }

    /// What the v3→v4 migrator stamps onto old projects (and what `Project`'s
    /// default initializer uses for fresh projects).
    public static let `default` = CursorSettings(isEnabled: true, scale: defaultScale)

    private enum CodingKeys: String, CodingKey {
        case isEnabled
        case scale
        case extras
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.isEnabled = try c.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        self.scale = try c.decodeIfPresent(Double.self, forKey: .scale) ?? Self.defaultScale
        self.extras = try c.decodeIfPresent([String: JSONValue].self, forKey: .extras) ?? [:]
    }
}

public extension CursorSettings {
    var zoomScaleBoostPerZoomUnit: Double {
        get { doubleExtra("zoomScaleBoostPerZoomUnit", default: Self.defaultZoomScaleBoostPerZoomUnit, range: Self.zoomScaleBoostPerZoomUnitRange) }
        set { setDoubleExtra("zoomScaleBoostPerZoomUnit", newValue, default: Self.defaultZoomScaleBoostPerZoomUnit, range: Self.zoomScaleBoostPerZoomUnitRange) }
    }

    var velocityScaleBoost: Double {
        get { doubleExtra("velocityScaleBoost", default: Self.defaultVelocityScaleBoost, range: Self.velocityScaleBoostRange) }
        set { setDoubleExtra("velocityScaleBoost", newValue, default: Self.defaultVelocityScaleBoost, range: Self.velocityScaleBoostRange) }
    }

    var velocityScaleLow: Double {
        get { doubleExtra("velocityScaleLow", default: Self.defaultVelocityScaleLow, range: Self.velocityScaleLowRange) }
        set { setDoubleExtra("velocityScaleLow", newValue, default: Self.defaultVelocityScaleLow, range: Self.velocityScaleLowRange) }
    }

    var velocityScaleHigh: Double {
        get { doubleExtra("velocityScaleHigh", default: Self.defaultVelocityScaleHigh, range: Self.velocityScaleHighRange) }
        set { setDoubleExtra("velocityScaleHigh", newValue, default: Self.defaultVelocityScaleHigh, range: Self.velocityScaleHighRange) }
    }

    var blurSpeedLow: Double {
        get { doubleExtra("blurSpeedLow", default: Self.defaultBlurSpeedLow, range: Self.blurSpeedLowRange) }
        set { setDoubleExtra("blurSpeedLow", newValue, default: Self.defaultBlurSpeedLow, range: Self.blurSpeedLowRange) }
    }

    var blurSpeedHigh: Double {
        get { doubleExtra("blurSpeedHigh", default: Self.defaultBlurSpeedHigh, range: Self.blurSpeedHighRange) }
        set { setDoubleExtra("blurSpeedHigh", newValue, default: Self.defaultBlurSpeedHigh, range: Self.blurSpeedHighRange) }
    }

    var blurShutterMin: Double {
        get { doubleExtra("blurShutterMin", default: Self.defaultBlurShutterMin, range: Self.blurShutterMinRange) }
        set { setDoubleExtra("blurShutterMin", newValue, default: Self.defaultBlurShutterMin, range: Self.blurShutterMinRange) }
    }

    var blurShutterMax: Double {
        get { doubleExtra("blurShutterMax", default: Self.defaultBlurShutterMax, range: Self.blurShutterMaxRange) }
        set { setDoubleExtra("blurShutterMax", newValue, default: Self.defaultBlurShutterMax, range: Self.blurShutterMaxRange) }
    }

    var blurMaxUV: Double {
        get { doubleExtra("blurMaxUV", default: Self.defaultBlurMaxUV, range: Self.blurMaxUVRange) }
        set { setDoubleExtra("blurMaxUV", newValue, default: Self.defaultBlurMaxUV, range: Self.blurMaxUVRange) }
    }

    private func doubleExtra(_ key: String, default defaultValue: Double, range: ClosedRange<Double>) -> Double {
        guard case .double(let value)? = extras[key] else { return defaultValue }
        return value.clamped(to: range)
    }

    private mutating func setDoubleExtra(_ key: String, _ value: Double, default defaultValue: Double, range: ClosedRange<Double>) {
        let clamped = value.clamped(to: range)
        if abs(clamped - defaultValue) < 0.000_001 {
            extras[key] = nil
        } else {
            extras[key] = .double(clamped)
        }
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
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
