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

    /// White halo thickness in image points. The synthetic cursor renders
    /// 3–6× larger than the OS cursor and gets a further zoom boost, so a
    /// 1.4 pt rim on the ~24 pt source reads as a clean ~6 % outline at any
    /// rendered size — enough to keep the cursor visible over dark UI and
    /// inside its own motion-blur streak, without looking like a sticker.
    private static let outlineRadiusPoints: CGFloat = 1.4

    /// Returns a `CursorSpriteData` derived from `NSCursor.arrow` (its
    /// image + hotSpot + intrinsic size), with a white outline baked in so
    /// the cursor stays visible against any background and inside its
    /// motion-blur trail. Returns nil if the conversion to `CGImage` fails
    /// (shouldn't happen on macOS 14+ for the system arrow cursor, but bail
    /// out gracefully rather than crash). Falls back to the bare cursor
    /// image if outline compositing fails.
    static func make() -> CursorSpriteData? {
        let cursor = NSCursor.arrow
        let nsImage = cursor.image
        let pointSize = nsImage.size
        var rect = CGRect(origin: .zero, size: pointSize)
        guard let cgImage = nsImage.cgImage(forProposedRect: &rect, context: nil, hints: nil) else {
            return nil
        }
        if let outlined = withWhiteOutline(cgImage, pointSize: pointSize, radiusPoints: outlineRadiusPoints) {
            // The halo pads the canvas on every side, so the intrinsic size
            // grows and the hot spot shifts by the same inset — keeping the
            // arrow tip aligned to the reported cursor position exactly.
            let inset = outlineRadiusPoints
            return CursorSpriteData(
                cgImage: outlined,
                pointSize: CGSize(width: pointSize.width + 2 * inset, height: pointSize.height + 2 * inset),
                hotSpot: CGPoint(x: cursor.hotSpot.x + inset, y: cursor.hotSpot.y + inset)
            )
        }
        return CursorSpriteData(
            cgImage: cgImage,
            pointSize: pointSize,
            hotSpot: cursor.hotSpot
        )
    }

    /// Composites a white halo behind the sprite: the sprite's alpha mask is
    /// stamped in solid white at 16 offsets around a circle of `radius` (plus
    /// 8 at half radius to fill the ring), then the original image draws on
    /// top. Runs once per composition build at the source image's native
    /// pixel density, so the result stays anti-aliased when the compositor
    /// scales it up.
    private static func withWhiteOutline(
        _ image: CGImage,
        pointSize: CGSize,
        radiusPoints: CGFloat
    ) -> CGImage? {
        guard pointSize.width > 0, pointSize.height > 0 else { return nil }
        let pixelScale = max(1, CGFloat(image.width) / pointSize.width)
        let radiusPx = radiusPoints * pixelScale
        let padPx = Int(ceil(radiusPx))
        let width = image.width + 2 * padPx
        let height = image.height + 2 * padPx
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .high

        let spriteRect = CGRect(
            x: CGFloat(padPx),
            y: CGFloat(padPx),
            width: CGFloat(image.width),
            height: CGFloat(image.height)
        )
        // Halo: clip to the sprite's alpha at each ring offset and flood
        // white. Two rings (full + half radius) close the gaps a single
        // 16-stop ring leaves at this thickness.
        let stops = 16
        for ring in [radiusPx, radiusPx * 0.55] {
            for i in 0..<stops {
                let angle = (CGFloat(i) / CGFloat(stops)) * 2 * .pi
                let offset = CGPoint(x: cos(angle) * ring, y: sin(angle) * ring)
                context.saveGState()
                context.translateBy(x: offset.x, y: offset.y)
                context.clip(to: spriteRect, mask: image)
                context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
                context.fill(spriteRect.insetBy(dx: -radiusPx * 2, dy: -radiusPx * 2))
                context.restoreGState()
            }
        }
        // Original sprite on top, centered in the padded canvas.
        context.draw(image, in: spriteRect)
        return context.makeImage()
    }
}
