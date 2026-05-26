import CoreGraphics
import Foundation
import PixelbayCore

// Identifies a logical layer in the compositor. Phase 1's hardcoded layout
// has at most two: a full-frame screen layer and an optional bottom-right
// webcam overlay. Audio doesn't pass through the video compositor (it lives
// on the AVMutableComposition's audio tracks, mixed by the AVPlayer).
//
// Phase 3a grows this with overlays / effects. Adding a case here forces
// MetalRenderGraph to handle it explicitly (Swift's exhaustive switching is
// the enforcement mechanism).
public enum LayerKind: String, Sendable, Hashable, CaseIterable {
    case screen
    case webcam
}

// Output-space rectangle in pixels. CGRect is convenient but not Sendable.
public struct LayerRect: Sendable, Equatable, Hashable {
    public var origin: CGPoint
    public var size: CGSize

    public init(origin: CGPoint, size: CGSize) {
        self.origin = origin
        self.size = size
    }

    public var minX: CGFloat { origin.x }
    public var minY: CGFloat { origin.y }
    public var maxX: CGFloat { origin.x + size.width }
    public var maxY: CGFloat { origin.y + size.height }
    public var midX: CGFloat { origin.x + size.width / 2 }
    public var midY: CGFloat { origin.y + size.height / 2 }

    public var cgRect: CGRect { CGRect(origin: origin, size: size) }
}

// Resolved per-frame layout for the compositor. Phase 3a generalises the
// shape:
//
// `outputSize` is the final framebuffer size in pixels.
// `background` describes a single fill pass drawn before any layer. `.none`
//   means clear-to-black (matches Phase 1 behavior).
// `screen` is always present and may be inset from the output bounds when
//   `LayoutPreset.padding > 0` and a background fills the surround.
// `screenCornerRadius` rounds the screen layer (for the "wallpaper with
//   rounded screen" look).
// `webcam` is nil when the recording had no camera enabled.
// `webcamCornerRadius` applies when `webcamShape == .rectangle`; for
//   `.circle` the render graph computes an inscribed-circle radius from the
//   webcam rect's shorter side and ignores this field.
public struct ResolvedLayout: Sendable, Equatable {
    public var outputSize: CGSize
    public var background: ResolvedBackground
    public var screen: LayerRect
    public var screenCornerRadius: CGFloat
    public var webcam: LayerRect?
    public var webcamShape: CamShape
    public var webcamCornerRadius: CGFloat
    // Per-layer multiplier applied after the corner-mask alpha. Phase 3b
    // talking-head crossfade lerps this from 0 → 1 over the keyframe's ease
    // window while the webcam rect is overlaid on the screen rect, so the
    // webcam crossfades in on top of the still-rendered screen layer.
    public var webcamOpacity: Float
    /// Phase 3d Gaussian blur sigma in pixels applied to the screen layer
    /// during zoom transitions. EffectEvaluator peaks this via the eased-
    /// strength bell (4·s·(1−s)) so it ramps in / out across ease-in and
    /// ease-out windows, and is zero during the held zoom — settled
    /// framing stays crisp. Replaces the Phase 3c radial zoom blur, which
    /// felt like light-speed warping during transitions. The shader
    /// normalises against the layer rect's size to produce symmetric soft
    /// veil on non-square viewports.
    public var screenZoomBlurSigmaPx: Float

    public init(
        outputSize: CGSize,
        background: ResolvedBackground,
        screen: LayerRect,
        screenCornerRadius: CGFloat,
        webcam: LayerRect?,
        webcamShape: CamShape,
        webcamCornerRadius: CGFloat,
        webcamOpacity: Float = 1.0,
        screenZoomBlurSigmaPx: Float = 0
    ) {
        self.outputSize = outputSize
        self.background = background
        self.screen = screen
        self.screenCornerRadius = screenCornerRadius
        self.webcam = webcam
        self.webcamShape = webcamShape
        self.webcamCornerRadius = webcamCornerRadius
        self.webcamOpacity = webcamOpacity
        self.screenZoomBlurSigmaPx = screenZoomBlurSigmaPx
    }
}

/// Phase 1-shaped type kept as a compatibility alias so any old call sites
/// can keep using the name. New code should use `ResolvedLayout`.
public typealias Phase1Layout = ResolvedLayout

/// The render-time form of `LayoutPreset.background`. Resolves the
/// system-wallpaper case to its `solid` fallback (the compositor itself
/// doesn't have access to NSWorkspace from package code; the app target
/// resolves the actual desktop image if needed before passing layout in).
public enum ResolvedBackground: Sendable, Equatable {
    case clear   // legacy "fill with black, no extra pass" — Phase 1 behavior
    case solid(SIMD4<Float>)
    case gradient(top: SIMD4<Float>, bottom: SIMD4<Float>)
}

// MARK: - LayoutCalculator

// Pure-data layout resolver. No Metal, no AVFoundation — unit-testable.
//
// Phase 1's `phase1Layout(...)` is preserved (returns a `ResolvedLayout`
// whose values exactly match the old hardcoded shape) so legacy call sites
// continue to compile and behave identically.
//
// Phase 3a's `resolve(preset:outputSize:hasWebcam:)` is the new entrypoint:
// take a `LayoutPreset` from `Project.layout` and produce the per-frame
// `ResolvedLayout`. Drives both preview and export.
public enum LayoutCalculator {
    // Phase 1 default cam: 240×135 pixels — the size called out in HANDOFF
    // §4.10. Kept for Phase 1 callers; new code resolves cam dimensions from
    // the preset's `CamSizePreset`.
    public static let webcamSize = CGSize(width: 240, height: 135)
    // Pixel inset from each edge for the Phase 1 PiP.
    public static let webcamMargin: CGFloat = 24
    // Phase 1 cam corner radius.
    public static let webcamCornerRadius: CGFloat = 12

    public static func phase1Layout(
        outputSize: CGSize,
        includeWebcam: Bool
    ) -> ResolvedLayout {
        ResolvedLayout(
            outputSize: outputSize,
            background: .clear,
            screen: LayerRect(origin: .zero, size: outputSize),
            screenCornerRadius: 0,
            webcam: includeWebcam ? phase1WebcamRect(outputSize: outputSize) : nil,
            webcamShape: .rectangle,
            webcamCornerRadius: webcamCornerRadius
        )
    }

    private static func phase1WebcamRect(outputSize: CGSize) -> LayerRect {
        let origin = CGPoint(
            x: outputSize.width - webcamSize.width - webcamMargin,
            y: outputSize.height - webcamSize.height - webcamMargin
        )
        return LayerRect(origin: origin, size: webcamSize)
    }

    /// Resolve a `LayoutPreset` against a concrete output size.
    ///
    /// `hasWebcam` controls whether the resolved layout includes a cam rect
    /// (cam-less recordings ignore the preset's cam settings — useful for
    /// previewing a screen-only recording without the user having to manually
    /// flip to a no-cam layout).
    public static func resolve(
        preset: LayoutPreset,
        outputSize: CGSize,
        hasWebcam: Bool
    ) -> ResolvedLayout {
        let background = resolveBackground(preset.background)
        let pad = max(0, CGFloat(preset.padding))
        let camShape = preset.camShape
        let camRadius = CGFloat(max(0, preset.camCornerRadius))
        let screenCornerRadius = CGFloat(max(0, preset.screenCornerRadius))

        switch preset.mode {
        case .pip(let position, let size):
            let screenRect: LayerRect
            if case .clear = background {
                // Phase 1 behavior: screen fills the output, ignoring padding.
                screenRect = LayerRect(origin: .zero, size: outputSize)
            } else {
                let inset = pad
                let width = max(2, outputSize.width - inset * 2)
                let height = max(2, outputSize.height - inset * 2)
                screenRect = LayerRect(
                    origin: CGPoint(x: inset, y: inset),
                    size: CGSize(width: width, height: height)
                )
            }
            let webcam: LayerRect?
            if hasWebcam {
                webcam = pipWebcamRect(
                    position: position,
                    size: size,
                    inside: screenRect
                )
            } else {
                webcam = nil
            }
            return ResolvedLayout(
                outputSize: outputSize,
                background: background,
                screen: screenRect,
                screenCornerRadius: screenCornerRadius,
                webcam: webcam,
                webcamShape: camShape,
                webcamCornerRadius: camRadius
            )

        case .splitHorizontal(let screenSide, let screenFractionRaw):
            let fraction = clampSplitFraction(screenFractionRaw)
            let screenWidth = max(2, floor(outputSize.width * fraction))
            let camWidth = max(2, outputSize.width - screenWidth)
            let screenRect: LayerRect
            let camRect: LayerRect
            switch screenSide {
            case .left:
                screenRect = LayerRect(origin: .zero, size: CGSize(width: screenWidth, height: outputSize.height))
                camRect = LayerRect(
                    origin: CGPoint(x: screenWidth, y: 0),
                    size: CGSize(width: camWidth, height: outputSize.height)
                )
            case .right:
                camRect = LayerRect(origin: .zero, size: CGSize(width: camWidth, height: outputSize.height))
                screenRect = LayerRect(
                    origin: CGPoint(x: camWidth, y: 0),
                    size: CGSize(width: screenWidth, height: outputSize.height)
                )
            }
            return ResolvedLayout(
                outputSize: outputSize,
                background: background,
                screen: screenRect,
                screenCornerRadius: screenCornerRadius,
                webcam: hasWebcam ? camRect : nil,
                webcamShape: camShape,
                webcamCornerRadius: camRadius
            )
        }
    }

    public static let webcamMargin3a: CGFloat = 24

    /// Discrete cam sizes (width-fraction of the screen container). Tuned so
    /// `.medium` matches the Phase 1 default of 240px at 1920px output.
    public static func camSizeFraction(_ preset: CamSizePreset) -> CGFloat {
        switch preset {
        case .small:  return 1.0 / 8.0
        case .medium: return 1.0 / 8.0 // 240 / 1920 = 0.125 ≈ matches phase 1
        case .large:  return 1.0 / 4.0
        }
    }

    /// 16:9 cam rect anchored to the given grid position inside `container`.
    public static func pipWebcamRect(
        position: CamPosition,
        size: CamSizePreset,
        inside container: LayerRect
    ) -> LayerRect {
        let camWidth = floor(container.size.width * camSizeFraction(size))
        let camHeight = floor(camWidth * 9.0 / 16.0)
        let margin = webcamMargin3a
        let camSize = CGSize(width: camWidth, height: camHeight)

        let minX = container.minX + margin
        let maxX = container.maxX - camWidth - margin
        let midX = container.midX - camWidth / 2
        let minY = container.minY + margin
        let maxY = container.maxY - camHeight - margin
        let midY = container.midY - camHeight / 2

        let origin: CGPoint
        switch position {
        case .topLeft:      origin = CGPoint(x: minX, y: minY)
        case .topCenter:    origin = CGPoint(x: midX, y: minY)
        case .topRight:     origin = CGPoint(x: maxX, y: minY)
        case .middleLeft:   origin = CGPoint(x: minX, y: midY)
        case .center:       origin = CGPoint(x: midX, y: midY)
        case .middleRight:  origin = CGPoint(x: maxX, y: midY)
        case .bottomLeft:   origin = CGPoint(x: minX, y: maxY)
        case .bottomCenter: origin = CGPoint(x: midX, y: maxY)
        case .bottomRight:  origin = CGPoint(x: maxX, y: maxY)
        }
        return LayerRect(origin: origin, size: camSize)
    }

    public static func clampSplitFraction(_ fraction: Double) -> CGFloat {
        CGFloat(min(0.9, max(0.1, fraction)))
    }

    private static func resolveBackground(_ background: Background) -> ResolvedBackground {
        switch background {
        case .none:
            return .clear
        case .solid(let color):
            return .solid(toSIMD(color))
        case .gradient(let from, let to):
            return .gradient(top: toSIMD(from), bottom: toSIMD(to))
        case .systemWallpaper(let fallback):
            // PixelbayCompositor has no AppKit dep; the app target resolves
            // the actual desktop image into a `.solid` (or pre-rendered
            // texture, eventually) before passing the preset here.
            return .solid(toSIMD(fallback))
        }
    }

    private static func toSIMD(_ c: RGBColor) -> SIMD4<Float> {
        SIMD4<Float>(Float(c.r), Float(c.g), Float(c.b), Float(c.a))
    }
}
