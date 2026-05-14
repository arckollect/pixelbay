import Foundation

// Phase 3a layout state. Lives on `Project.layout`. Drives the compositor's
// resolved per-frame layout via `PixelbayCompositor.LayoutCalculator.resolve(...)`.
//
// Defaults preserve Phase 1 behavior: bottom-right PiP, 240×135 cam at the
// project's render resolution, 12pt rounded rectangle, no background — see
// `phase1Default`.
//
// Schema: this struct is a top-level field on `Project` from schemaVersion 2
// onward; the v1→v2 migrator (`Migrator1To2`) fills it in for old projects.

public struct LayoutPreset: Codable, Sendable, Equatable {
    public var mode: LayoutMode
    public var camShape: CamShape
    public var camCornerRadius: Double      // pixels at project render res; ignored when camShape == .circle
    public var background: Background
    // Pixels of padding between the screen layer and the output edges. Only
    // applied when background is non-`.none` (otherwise the screen fills the
    // output as before — Phase 1 behavior).
    public var padding: Double
    // Rounded-rect radius applied to the SCREEN layer itself (for the
    // "wallpaper with rounded screen" look). 0 = no rounding.
    public var screenCornerRadius: Double
    public var extras: [String: JSONValue]

    public init(
        mode: LayoutMode = .pip(position: .bottomRight, size: .medium),
        camShape: CamShape = .rectangle,
        camCornerRadius: Double = 12,
        background: Background = .none,
        padding: Double = 0,
        screenCornerRadius: Double = 0,
        extras: [String: JSONValue] = [:]
    ) {
        self.mode = mode
        self.camShape = camShape
        self.camCornerRadius = camCornerRadius
        self.background = background
        self.padding = padding
        self.screenCornerRadius = screenCornerRadius
        self.extras = extras
    }

    /// The layout that the v1→v2 migrator stamps onto pre-Phase-3a projects.
    /// Visually identical to the hardcoded Phase 1 look so existing recordings
    /// preview the same way after migration.
    public static let phase1Default = LayoutPreset(
        mode: .pip(position: .bottomRight, size: .medium),
        camShape: .rectangle,
        camCornerRadius: 12,
        background: .none,
        padding: 0,
        screenCornerRadius: 0
    )

    private enum CodingKeys: String, CodingKey {
        case mode
        case camShape
        case camCornerRadius
        case background
        case padding
        case screenCornerRadius
        case extras
    }
}

// MARK: - LayoutMode

// Top-level cam arrangement.
//
// - `pip`: classic picture-in-picture — screen fills the output (minus padding
//   when a background is set) and the cam floats over it at one of the nine
//   grid positions. Cam size is chosen via a discrete preset (so changing the
//   project's render resolution doesn't surprise the user with a too-small or
//   too-large cam).
// - `splitHorizontal`: 70/30 horizontal split — screen on one side, cam on
//   the other. `screenFraction` ∈ [0.1, 0.9] is the screen's share of the
//   output width.
public enum LayoutMode: Codable, Sendable, Equatable {
    case pip(position: CamPosition, size: CamSizePreset)
    case splitHorizontal(screenSide: HorizontalSide, screenFraction: Double)

    private enum CodingKeys: String, CodingKey {
        case kind
        case position
        case size
        case screenSide
        case screenFraction
    }

    private enum Kind: String, Codable { case pip; case splitHorizontal }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(Kind.self, forKey: .kind)
        switch kind {
        case .pip:
            self = .pip(
                position: try c.decode(CamPosition.self, forKey: .position),
                size: try c.decode(CamSizePreset.self, forKey: .size)
            )
        case .splitHorizontal:
            self = .splitHorizontal(
                screenSide: try c.decode(HorizontalSide.self, forKey: .screenSide),
                screenFraction: try c.decode(Double.self, forKey: .screenFraction)
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .pip(let position, let size):
            try c.encode(Kind.pip, forKey: .kind)
            try c.encode(position, forKey: .position)
            try c.encode(size, forKey: .size)
        case .splitHorizontal(let side, let fraction):
            try c.encode(Kind.splitHorizontal, forKey: .kind)
            try c.encode(side, forKey: .screenSide)
            try c.encode(fraction, forKey: .screenFraction)
        }
    }
}

/// 3x3 grid of cam positions inside the screen frame for PiP mode.
public enum CamPosition: String, Codable, Sendable, CaseIterable {
    case topLeft
    case topCenter
    case topRight
    case middleLeft
    case center
    case middleRight
    case bottomLeft
    case bottomCenter
    case bottomRight
}

/// Discrete cam size buckets. Resolved to pixel dimensions by
/// `LayoutCalculator` based on output size. Discrete (not freely tunable)
/// because the cam-size slider is the kind of thing that produces ten near-
/// identical undo entries during a single user gesture in early UX testing.
public enum CamSizePreset: String, Codable, Sendable, CaseIterable {
    case small      // ≈ 1/8 width
    case medium     // ≈ 1/6 width (the Phase 1 default of 240×135 at 1080p)
    case large      // ≈ 1/4 width
}

public enum HorizontalSide: String, Codable, Sendable, CaseIterable {
    case left
    case right
}

// MARK: - CamShape

/// Outline shape applied to the cam layer in the compositor. Rectangle uses
/// `LayoutPreset.camCornerRadius`; circle ignores it (the compositor masks to
/// an inscribed circle).
public enum CamShape: String, Codable, Sendable, CaseIterable {
    case rectangle
    case circle
}

// MARK: - Background

/// Background fill behind / around the screen layer when padded.
///
/// - `.none` is the Phase 1 behavior: no padding, screen fills the output.
/// - `.solid` fills with a single color.
/// - `.gradient` linearly interpolates between two colors top→bottom.
/// - `.systemWallpaper` is reserved for Phase 3a follow-up (reading the
///   current desktop image from `NSWorkspace.shared.desktopImageURL`); the
///   compositor falls back to `solid` when this can't be resolved.
public enum Background: Codable, Sendable, Equatable {
    case none
    case solid(color: RGBColor)
    case gradient(from: RGBColor, to: RGBColor)
    case systemWallpaper(fallback: RGBColor)

    private enum CodingKeys: String, CodingKey {
        case kind
        case color
        case from
        case to
        case fallback
    }

    private enum Kind: String, Codable {
        case none
        case solid
        case gradient
        case systemWallpaper
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(Kind.self, forKey: .kind)
        switch kind {
        case .none:
            self = .none
        case .solid:
            self = .solid(color: try c.decode(RGBColor.self, forKey: .color))
        case .gradient:
            self = .gradient(
                from: try c.decode(RGBColor.self, forKey: .from),
                to: try c.decode(RGBColor.self, forKey: .to)
            )
        case .systemWallpaper:
            self = .systemWallpaper(
                fallback: try c.decode(RGBColor.self, forKey: .fallback)
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .none:
            try c.encode(Kind.none, forKey: .kind)
        case .solid(let color):
            try c.encode(Kind.solid, forKey: .kind)
            try c.encode(color, forKey: .color)
        case .gradient(let from, let to):
            try c.encode(Kind.gradient, forKey: .kind)
            try c.encode(from, forKey: .from)
            try c.encode(to, forKey: .to)
        case .systemWallpaper(let fallback):
            try c.encode(Kind.systemWallpaper, forKey: .kind)
            try c.encode(fallback, forKey: .fallback)
        }
    }
}

/// Linear-color RGB. Components in 0...1. We deliberately avoid coupling to
/// AppKit / SwiftUI here so the model stays cross-platform-safe and Sendable.
public struct RGBColor: Codable, Sendable, Equatable, Hashable {
    public var r: Double
    public var g: Double
    public var b: Double
    public var a: Double

    public init(r: Double, g: Double, b: Double, a: Double = 1) {
        self.r = r
        self.g = g
        self.b = b
        self.a = a
    }

    public static let black = RGBColor(r: 0, g: 0, b: 0)
    public static let white = RGBColor(r: 1, g: 1, b: 1)

    private enum CodingKeys: String, CodingKey {
        case r
        case g
        case b
        case a
    }
}
