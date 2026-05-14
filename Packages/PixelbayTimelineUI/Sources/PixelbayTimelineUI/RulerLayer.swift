#if canImport(AppKit)
import AppKit
import CoreGraphics
import QuartzCore

// Draws the timeline's ruler strip: tick marks + time labels above the
// track lanes. Re-renders when zoom (pixelsPerSecond), scroll, or layout
// width changes — but NOT on every playhead tick (the playhead is its own
// layer). Lives in PixelbayTimelineUI alongside WaveformLayer so the
// rendering primitives stay together.
//
// Tick density follows TimelineLayoutCalculator.niceTickInterval(...).
// Major ticks carry an "M:SS" label (or "M:SS.ss" at high zoom); minor
// ticks are short hashes between them. Labels are clamped to start at
// `headerWidth` so they don't bleed into the track-header column.
public final class RulerLayer: CALayer, @unchecked Sendable {
    public var pixelsPerSecond: CGFloat = TimelineLayoutCalculator.defaultPixelsPerSecond {
        didSet { if oldValue != pixelsPerSecond { setNeedsDisplay() } }
    }
    public var scrollSeconds: CGFloat = 0 {
        didSet { if oldValue != scrollSeconds { setNeedsDisplay() } }
    }
    public var headerWidth: CGFloat = TimelineLayoutCalculator.trackHeaderWidth {
        didSet { if oldValue != headerWidth { setNeedsDisplay() } }
    }

    public override init() {
        super.init()
        setUp()
    }

    public override init(layer: Any) {
        super.init(layer: layer)
        setUp()
        if let other = layer as? RulerLayer {
            self.pixelsPerSecond = other.pixelsPerSecond
            self.scrollSeconds = other.scrollSeconds
            self.headerWidth = other.headerWidth
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    private func setUp() {
        contentsScale = NSScreen.main?.backingScaleFactor ?? 2
        needsDisplayOnBoundsChange = true
        backgroundColor = NSColor.controlBackgroundColor.cgColor
    }

    public override func draw(in ctx: CGContext) {
        let bounds = self.bounds
        guard bounds.width > 0, bounds.height > 0 else { return }

        // Bottom hairline that visually separates the ruler from the lanes.
        ctx.setFillColor(NSColor.separatorColor.cgColor)
        ctx.fill(CGRect(x: 0, y: bounds.maxY - 0.5, width: bounds.width, height: 0.5))

        let intervals = TimelineLayoutCalculator.niceTickInterval(forPixelsPerSecond: pixelsPerSecond)
        let pps = max(TimelineLayoutCalculator.minPixelsPerSecond,
                      min(TimelineLayoutCalculator.maxPixelsPerSecond, pixelsPerSecond))

        // Visible time window in the ruler's coordinate space. The lane
        // starts at x=headerWidth and runs to bounds.maxX.
        let laneWidth = bounds.width - headerWidth
        guard laneWidth > 0 else { return }
        let firstSecond = max(0, Double(scrollSeconds))
        let lastSecond = Double(scrollSeconds) + Double(laneWidth / pps)

        // Minor ticks first (so major overpaints them at exact alignments).
        if intervals.minor < intervals.major {
            ctx.setStrokeColor(NSColor.tertiaryLabelColor.cgColor)
            ctx.setLineWidth(1)
            drawTicks(
                in: ctx,
                bounds: bounds,
                intervalSeconds: intervals.minor,
                firstSecond: firstSecond,
                lastSecond: lastSecond,
                pps: pps,
                tickHeight: 4
            )
        }

        // Major ticks + labels.
        ctx.setStrokeColor(NSColor.secondaryLabelColor.cgColor)
        ctx.setLineWidth(1)
        drawTicks(
            in: ctx,
            bounds: bounds,
            intervalSeconds: intervals.major,
            firstSecond: firstSecond,
            lastSecond: lastSecond,
            pps: pps,
            tickHeight: 8
        )
        drawLabels(
            in: ctx,
            bounds: bounds,
            intervalSeconds: intervals.major,
            firstSecond: firstSecond,
            lastSecond: lastSecond,
            pps: pps
        )
    }

    private func drawTicks(
        in ctx: CGContext,
        bounds: CGRect,
        intervalSeconds: Double,
        firstSecond: Double,
        lastSecond: Double,
        pps: CGFloat,
        tickHeight: CGFloat
    ) {
        guard intervalSeconds > 0 else { return }
        let firstIndex = Int(floor(firstSecond / intervalSeconds))
        let lastIndex = Int(ceil(lastSecond / intervalSeconds))
        guard lastIndex >= firstIndex else { return }
        ctx.beginPath()
        for i in firstIndex...lastIndex {
            let t = Double(i) * intervalSeconds
            if t < 0 { continue }
            let x = headerWidth + (CGFloat(t) - scrollSeconds) * pps
            if x < headerWidth - 0.5 { continue }
            if x > bounds.maxX + 0.5 { break }
            let xSnapped = (x.rounded()) + 0.5  // crisp 1px line
            ctx.move(to: CGPoint(x: xSnapped, y: bounds.maxY - tickHeight))
            ctx.addLine(to: CGPoint(x: xSnapped, y: bounds.maxY))
        }
        ctx.strokePath()
    }

    private func drawLabels(
        in ctx: CGContext,
        bounds: CGRect,
        intervalSeconds: Double,
        firstSecond: Double,
        lastSecond: Double,
        pps: CGFloat
    ) {
        guard intervalSeconds > 0 else { return }
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular),
            .foregroundColor: NSColor.secondaryLabelColor
        ]
        let firstIndex = Int(floor(firstSecond / intervalSeconds))
        let lastIndex = Int(ceil(lastSecond / intervalSeconds))
        guard lastIndex >= firstIndex else { return }
        // Push the CGContext as the current NSGraphicsContext so
        // NSAttributedString.draw uses our ruler context (flipped Y to
        // match TimelineNSView.isFlipped).
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        let nsctx = NSGraphicsContext(cgContext: ctx, flipped: true)
        NSGraphicsContext.current = nsctx

        for i in firstIndex...lastIndex {
            let t = Double(i) * intervalSeconds
            if t < 0 { continue }
            let x = headerWidth + (CGFloat(t) - scrollSeconds) * pps
            if x < headerWidth { continue }
            if x > bounds.maxX { break }
            let label = formatLabel(seconds: t, intervalSeconds: intervalSeconds) as NSString
            let size = label.size(withAttributes: attrs)
            // Anchor labels just to the right of the tick. Clamp left edge so
            // labels never overlap the track-header column even mid-scroll.
            let labelX = max(headerWidth + 2, x + 3)
            // Top-aligned in the ruler, 1pt of breathing room.
            label.draw(at: CGPoint(x: labelX, y: 1), withAttributes: attrs)
            _ = size
        }
    }

    /// "M:SS" for whole-second intervals. "M:SS.s" or "M:SS.ss" once the
    /// interval drops below 1 second so users can read sub-second times.
    private func formatLabel(seconds t: Double, intervalSeconds: Double) -> String {
        let totalMinutes = Int(t) / 60
        let secs = t.truncatingRemainder(dividingBy: 60)
        if intervalSeconds >= 1 {
            return String(format: "%d:%02d", totalMinutes, Int(secs.rounded()))
        } else if intervalSeconds >= 0.1 {
            return String(format: "%d:%04.1f", totalMinutes, secs)
        } else {
            return String(format: "%d:%05.2f", totalMinutes, secs)
        }
    }
}
#endif
