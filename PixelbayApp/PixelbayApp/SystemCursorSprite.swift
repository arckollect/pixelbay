import AppKit
import CoreGraphics
import PixelbayCompositor

// App-target glue: build a `CursorSpriteData` from the live system cursor
// so the compositor (which is AppKit-free) can render a synthetic cursor
// at user-adjustable scale on top of the screen layer.
//
// Phase 3c rationale (2026-05-14): rather than ship a bundled PNG, we
// snapshot whatever the user's system cursor is at the time the preview /
// export composition is built. This trades reproducibility (a cursor-pref
// change between recording and export will show the new shape) for
// "looks like *my* cursor", which is what most users expect from a
// screen-recording tool. v2 can capture per-state cursor shapes (arrow,
// I-beam, hand) by hooking `NSCursor.current` during capture.

enum SystemCursorSprite {

    /// Returns a `CursorSpriteData` derived from `NSCursor.arrow` (its
    /// image + hotSpot + intrinsic size). Returns nil if the conversion
    /// to `CGImage` fails (shouldn't happen on macOS 14+ for the system
    /// arrow cursor, but bail out gracefully rather than crash).
    static func make() -> CursorSpriteData? {
        let cursor = NSCursor.arrow
        let nsImage = cursor.image
        let pointSize = nsImage.size
        var rect = CGRect(origin: .zero, size: pointSize)
        guard let cgImage = nsImage.cgImage(forProposedRect: &rect, context: nil, hints: nil) else {
            return nil
        }
        return CursorSpriteData(
            cgImage: cgImage,
            pointSize: pointSize,
            hotSpot: cursor.hotSpot
        )
    }
}
