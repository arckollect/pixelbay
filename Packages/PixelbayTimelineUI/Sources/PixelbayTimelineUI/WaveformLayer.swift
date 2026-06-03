#if canImport(AppKit)
import AppKit
import CoreGraphics
import PixelbayDesignSystem
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
    public var fillColor: CGColor = Theme.NSColor.waveformFill.cgColor {
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
        let midY = bounds.height / 2
        // Fill most of the clip — only a sliver of headroom top/bottom.
        let halfHeight = (bounds.height / 2) * 0.94
        let bucketCount = peaks.bucketCount

        // Faint center baseline so a clip ALWAYS reads as an audio track —
        // even before peaks load or when the source is near-silent.
        ctx.setFillColor(fillColor.copy(alpha: 0.28) ?? fillColor)
        ctx.fill(CGRect(x: bounds.minX, y: midY - 0.5, width: bounds.width, height: 1))

        guard bucketCount > 0 else { return }

        // DISPLAY NORMALISATION (industry standard): scale so the loudest
        // bucket reaches ~95% of the half-height, so quiet-but-present audio
        // still fills the lane instead of rendering as a flat line. Capped at
        // 8× so genuine near-silence/noise isn't amplified into a false signal.
        var maxAbs: Float = 0
        for i in 0..<bucketCount {
            maxAbs = Swift.max(maxAbs, Swift.abs(peaks.min[i]), Swift.abs(peaks.max[i]))
        }
        // High cap so quiet-but-present audio (e.g. a screencast mic) still
        // fills the lane like pro editors do — not a timid 8×.
        let gain: CGFloat = maxAbs > 0.0001 ? Swift.min(50.0, 0.98 / CGFloat(maxAbs)) : 1

        let barWidth: CGFloat = 1
        ctx.setFillColor(fillColor)
        for i in 0..<bucketCount {
            let xRatio = CGFloat(i) / CGFloat(bucketCount)
            let x = bounds.minX + xRatio * bounds.width
            // Both peaks could be on the same side of zero (mostly-positive
            // or mostly-negative bucket); the bar still spans [min, max].
            let mx = Swift.min(1, CGFloat(peaks.max[i]) * gain)
            let mn = Swift.max(-1, CGFloat(peaks.min[i]) * gain)
            let yTop = midY - mx * halfHeight
            let yBottom = midY - mn * halfHeight
            let height = max(1, yBottom - yTop)
            ctx.fill(CGRect(x: x, y: yTop, width: barWidth, height: height))
        }
    }
}
#endif
