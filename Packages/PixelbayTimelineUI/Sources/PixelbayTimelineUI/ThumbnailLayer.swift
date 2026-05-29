#if canImport(AppKit)
import AppKit
import CoreGraphics
import QuartzCore

// CALayer strip that hosts one image sublayer per thumbnail tile across a
// video clip's width. TimelineNSView creates one per video clip, sizes it to
// the clip's inset frame, then kicks off async `ThumbnailLoader` loads and
// drops a tile in as each resolves (so the strip fills progressively rather
// than waiting on the slowest frame).
//
// Audio clips use `WaveformLayer` instead; non-video/non-audio clips get
// neither (their tinted body shows through).
public final class ThumbnailLayer: CALayer, @unchecked Sendable {
    public override init() {
        super.init()
        setUp()
    }

    public override init(layer: Any) {
        super.init(layer: layer)
        setUp()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    private func setUp() {
        masksToBounds = true
        contentsScale = NSScreen.main?.backingScaleFactor ?? 2
    }

    /// Adds one thumbnail tile at `frame` (in this layer's coordinate space).
    /// `.resizeAspectFill` crops to fill so adjacent tiles line up edge-to-edge
    /// with no letterboxing.
    public func addTile(cgImage: CGImage, frame: CGRect) {
        let tile = CALayer()
        tile.frame = frame
        tile.contents = cgImage
        tile.contentsGravity = .resizeAspectFill
        tile.masksToBounds = true
        tile.contentsScale = contentsScale
        addSublayer(tile)
    }
}
#endif
