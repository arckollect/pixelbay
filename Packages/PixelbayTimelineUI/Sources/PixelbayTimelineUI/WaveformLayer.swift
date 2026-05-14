#if canImport(AppKit)
import AppKit
import CoreGraphics
import QuartzCore

// Renders a WaveformPeaks via direct CGContext drawing — one vertical
// bar per bucket from min to max, scaled to fit the layer height.
// Cheap to redraw (single-pass per bucket) and cached by CALayer's
// own contents bitmap.
//
// Used by TimelineNSView for audio TrackKinds; non-audio clips skip
// the WaveformLayer entirely. Peaks are loaded async via
// WaveformLoader; while loading, this layer renders empty (no fill),
// so the user sees the clip body's background until peaks resolve.
public final class WaveformLayer: CALayer, @unchecked Sendable {
    public var peaks: WaveformPeaks = .empty {
        didSet {
            if peaks != oldValue {
                setNeedsDisplay()
            }
        }
    }
    public var fillColor: CGColor = NSColor.controlAccentColor.cgColor {
        didSet {
            if fillColor != oldValue {
                setNeedsDisplay()
            }
        }
    }

    public override init() {
        super.init()
        setUp()
    }

    public override init(layer: Any) {
        super.init(layer: layer)
        setUp()
        if let other = layer as? WaveformLayer {
            self.peaks = other.peaks
            self.fillColor = other.fillColor
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    private func setUp() {
        // CGContext-based drawing path; the OS will rasterize once and
        // cache the bitmap until peaks change.
        contentsScale = NSScreen.main?.backingScaleFactor ?? 2
        needsDisplayOnBoundsChange = true
        masksToBounds = true
    }

    public override func draw(in ctx: CGContext) {
        let bounds = self.bounds
        guard bounds.width > 0, bounds.height > 0 else { return }
        let bucketCount = peaks.bucketCount
        guard bucketCount > 0 else { return }
        // 1px bars; map bucket index → x coordinate proportionally.
        let barWidth: CGFloat = 1
        let midY = bounds.height / 2
        let halfHeight = bounds.height / 2
        ctx.setFillColor(fillColor)

        for i in 0..<bucketCount {
            let xRatio = CGFloat(i) / CGFloat(bucketCount)
            let x = bounds.minX + xRatio * bounds.width
            let mn = max(-1, min(1, peaks.min[i]))
            let mx = max(-1, min(1, peaks.max[i]))
            // Both peaks could be on the same side of zero (mostly-positive
            // or mostly-negative bucket); the bar still spans [min, max].
            let yTop = midY - CGFloat(mx) * halfHeight
            let yBottom = midY - CGFloat(mn) * halfHeight
            let height = max(1, yBottom - yTop)  // at least 1px so silence still shows a midline
            ctx.fill(CGRect(x: x, y: yTop, width: barWidth, height: height))
        }
    }
}
#endif
