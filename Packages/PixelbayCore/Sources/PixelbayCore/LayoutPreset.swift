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

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.mode = try c.decodeIfPresent(LayoutMode.self, forKey: .mode)
            ?? .pip(position: .bottomRight, size: .medium)
        self.camShape = try c.decodeIfPresent(CamShape.self, forKey: .camShape) ?? .rectangle
        self.camCornerRadius = try c.decodeIfPresent(Double.self, forKey: .camCornerRadius) ?? 12
        self.background = try c.decodeIfPresent(Background.self, forKey: .background) ?? .none
        self.padding = try c.decodeIfPresent(Double.self, forKey: .padding) ?? 0
        self.screenCornerRadius = try c.decodeIfPresent(Double.self, forKey: .screenCornerRadius) ?? 0
        self.extras = try c.decodeIfPresent([String: JSONValue].self, forKey: .extras) ?? [:]
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
    /// A curated "wallpaper" — a soft multi-blob mesh gradient (the Screen
    /// Studio / Loom look). Self-contained (carries its own base + blobs) so
    /// it serializes without a shared preset registry and old projects keep
    /// rendering even if the app's preset catalog later changes.
    case wallpaper(WallpaperGradient)
    /// An image wallpaper — either a built-in bundled with the app or a
    /// user-uploaded file copied into the project bundle. The pixels live
    /// outside the model (resolved at render time from `WallpaperImageRef`);
    /// `fallback` is shown if the image can't be loaded.
    case image(WallpaperImageRef)

    private enum CodingKeys: String, CodingKey {
        case kind
        case color
        case from
        case to
        case fallback
        case wallpaper
        case image
    }

    private enum Kind: String, Codable {
        case none
        case solid
        case gradient
        case systemWallpaper
        case wallpaper
        case image
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
        case .wallpaper:
            self = .wallpaper(try c.decode(WallpaperGradient.self, forKey: .wallpaper))
        case .image:
            self = .image(try c.decode(WallpaperImageRef.self, forKey: .image))
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
        case .wallpaper(let wallpaper):
            try c.encode(Kind.wallpaper, forKey: .kind)
            try c.encode(wallpaper, forKey: .wallpaper)
        case .image(let ref):
            try c.encode(Kind.image, forKey: .kind)
            try c.encode(ref, forKey: .image)
        }
    }
}

/// Reference to an image wallpaper. Exactly one of `builtinID` (a wallpaper
/// bundled with the app, keyed by its file's base name) or `relativePath` (a
/// user upload copied into the project bundle, path relative to the bundle
/// root) is non-nil. The pixels are loaded at render time; `fallback` is the
/// flat colour shown if loading fails. `name` is the display label.
public struct WallpaperImageRef: Codable, Sendable, Equatable, Hashable {
    public var name: String
    public var builtinID: String?
    public var relativePath: String?
    public var fallback: RGBColor

    public init(
        name: String,
        builtinID: String? = nil,
        relativePath: String? = nil,
        fallback: RGBColor = RGBColor(r: 0.10, g: 0.11, b: 0.14)
    ) {
        self.name = name
        self.builtinID = builtinID
        self.relativePath = relativePath
        self.fallback = fallback
    }

    public static func builtin(id: String, name: String, fallback: RGBColor = RGBColor(r: 0.10, g: 0.11, b: 0.14)) -> WallpaperImageRef {
        WallpaperImageRef(name: name, builtinID: id, fallback: fallback)
    }

    public static func upload(relativePath: String, name: String, fallback: RGBColor = RGBColor(r: 0.10, g: 0.11, b: 0.14)) -> WallpaperImageRef {
        WallpaperImageRef(name: name, relativePath: relativePath, fallback: fallback)
    }
}

/// A procedural "wallpaper" background: a base fill with a handful of soft
/// radial color blobs blended over it (a mesh gradient). Both the Metal
/// compositor and the SwiftUI inspector swatch render from this same data, so
/// the picker preview matches the exported frame.
///
/// Coordinates are normalized: `x`/`y` in 0...1 (0,0 = top-left of the output),
/// `radius` in units of output HEIGHT (the renderer aspect-corrects x so blobs
/// stay circular on a wide frame). `color.a` is the blob's blend strength at
/// its centre (0...1), not classic opacity.
public struct WallpaperGradient: Codable, Sendable, Equatable, Hashable {
    public struct Blob: Codable, Sendable, Equatable, Hashable {
        public var color: RGBColor
        public var x: Double
        public var y: Double
        public var radius: Double

        public init(color: RGBColor, x: Double, y: Double, radius: Double) {
            self.color = color
            self.x = x
            self.y = y
            self.radius = radius
        }
    }

    /// Stable identifier for the source preset (display name). Lets the UI
    /// highlight the active swatch and label it without comparing every blob.
    public var name: String
    public var base: RGBColor
    public var blobs: [Blob]

    public init(name: String, base: RGBColor, blobs: [Blob]) {
        self.name = name
        self.base = base
        self.blobs = blobs
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
