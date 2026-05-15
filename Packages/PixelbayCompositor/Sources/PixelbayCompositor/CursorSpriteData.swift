import CoreGraphics
import Foundation

// Phase 3c — sprite + hotspot for the synthetic cursor pass.
//
// The app target builds this once (typically from `NSCursor.arrow.image`)
// and threads it into `PixelbayCompositionInstruction.cursorSprite`, so the
// compositor package can stay AppKit-free and unit-testable. CGImage is
// reference-typed and not natively Sendable, but the instance is treated
// as immutable for the lifetime of the composition, so the wrapper is
// marked `@unchecked Sendable` — the same pattern the instruction itself
// uses.
public struct CursorSpriteData: @unchecked Sendable {
    public let cgImage: CGImage
    /// Intrinsic size in points (e.g. the NSImage size — usually 16×24 for
    /// the arrow cursor). Used together with `outputHeight` and
    /// `CursorSettings.scale` to compute the cursor's pixel size in the
    /// output frame.
    public let pointSize: CGSize
    /// The pixel inside the sprite that should align with the cursor's
    /// reported (x, y) position, in image points (top-left origin to match
    /// AppKit's NSCursor.hotSpot convention).
    public let hotSpot: CGPoint

    public init(cgImage: CGImage, pointSize: CGSize, hotSpot: CGPoint) {
        self.cgImage = cgImage
        self.pointSize = pointSize
        self.hotSpot = hotSpot
    }
}

// Per-frame state the compositor passes to `MetalRenderGraph.render` when
// the synthetic-cursor pass is active. The compositor samples the master
// trajectory at the frame's composition time, maps the normalised (x,y)
// fraction into the (possibly zoomed) screen rect, and hands the resolved
// fields here.
public struct CursorRenderState: Sendable {
    /// Normalised cursor position in screen-content space, [0…1]. The
    /// caller is responsible for mapping this against `layout.screen`
    /// AFTER any zoom transform has been applied — so the cursor tracks
    /// the zoom-in framing automatically (zoom moves `layout.screen.minX`
    /// and grows `width`, and the cursor stays at the same content
    /// fraction).
    public let xFractionInScreen: Double
    public let yFractionInScreen: Double
    /// User-facing scale multiplier (from `CursorSettings.scale`).
    public let scale: Double
    /// Instantaneous cursor velocity in screen-content fraction per second
    /// (same coordinate space as `xFractionInScreen`). Drives the motion-blur
    /// kernel in the cursor fragment shader: tap offsets are aligned to this
    /// vector so a fast-moving cursor reads as a soft streak rather than
    /// strobing once-per-frame. Zero magnitude (cursor stationary) collapses
    /// the kernel back to a single sample.
    public let velocityXFractionPerSecond: Double
    public let velocityYFractionPerSecond: Double

    public init(
        xFractionInScreen: Double,
        yFractionInScreen: Double,
        scale: Double,
        velocityXFractionPerSecond: Double = 0,
        velocityYFractionPerSecond: Double = 0
    ) {
        self.xFractionInScreen = xFractionInScreen
        self.yFractionInScreen = yFractionInScreen
        self.scale = scale
        self.velocityXFractionPerSecond = velocityXFractionPerSecond
        self.velocityYFractionPerSecond = velocityYFractionPerSecond
    }
}
