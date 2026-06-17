import Foundation

// Pure value-space geometry for the interactive preview transform. Operating on
// `NormalizedRect` (0…1 output space) keeps this resolution-independent and —
// crucially — UI-framework-free, so the fiddly clamp / aspect-lock / snap math
// that drives the drag overlay is unit-testable in PixelbayCore rather than
// stranded in the app target (which has no test bundle).

/// The four draggable corners of a rect.
public enum RectCorner: CaseIterable, Sendable, Hashable {
    case topLeft, topRight, bottomLeft, bottomRight

    /// The corner diagonally opposite — the fixed anchor while this one drags.
    public var opposite: RectCorner {
        switch self {
        case .topLeft: return .bottomRight
        case .topRight: return .bottomLeft
        case .bottomLeft: return .topRight
        case .bottomRight: return .topLeft
        }
    }

    var isLeft: Bool { self == .topLeft || self == .bottomLeft }
    var isTop: Bool { self == .topLeft || self == .topRight }
}

public extension NormalizedRect {
    var minX: Double { x }
    var minY: Double { y }
    var maxX: Double { x + width }
    var maxY: Double { y + height }
    var midX: Double { x + width / 2 }
    var midY: Double { y + height / 2 }

    /// Normalized point of a given corner.
    func corner(_ c: RectCorner) -> (x: Double, y: Double) {
        (c.isLeft ? minX : maxX, c.isTop ? minY : maxY)
    }

    /// Shift the origin so the whole rect lies within the unit square without
    /// resizing (assumes width,height ≤ 1; otherwise pins to the top-left).
    func clampedTranslatedIntoUnit() -> NormalizedRect {
        var r = self
        r.x = min(max(0, r.x), max(0, 1 - r.width))
        r.y = min(max(0, r.y), max(0, 1 - r.height))
        return r
    }

    /// Translate by a normalized delta and keep the rect fully on-canvas.
    func translated(dx: Double, dy: Double) -> NormalizedRect {
        var r = self
        r.x += dx
        r.y += dy
        return r.clampedTranslatedIntoUnit()
    }

    /// Aspect-locked corner resize. Drags `corner` toward `(px, py)` (normalized,
    /// clamped to the canvas) while pinning the opposite corner, locking
    /// width:height to `aspect`, never shrinking below `minWidth`, and keeping
    /// the whole result inside the unit square.
    ///
    /// - aspect: width / height of the layer (16/9 for a rectangle cam, 1 for a
    ///   circle, the screen's own aspect for the screen).
    func resized(
        draggingCorner corner: RectCorner,
        toX pxRaw: Double,
        toY pyRaw: Double,
        aspect: Double,
        minWidth: Double
    ) -> NormalizedRect {
        let aspect = max(0.0001, aspect)
        // The anchor (opposite corner) stays fixed.
        let anchor = self.corner(corner.opposite)
        let px = min(max(0, pxRaw), 1)
        let py = min(max(0, pyRaw), 1)

        // Candidate size from the dragged distance on each axis; take the larger
        // so the rect tracks whichever way the cursor pulled hardest, then lock
        // height to the aspect ratio.
        let widthFromX = abs(px - anchor.x)
        let widthFromY = abs(py - anchor.y) * aspect
        var newWidth = max(widthFromX, widthFromY)

        // Cap so the rect can't leave the canvas while the anchor stays pinned.
        let maxWidthByX = corner.isLeft ? anchor.x : (1 - anchor.x)
        let maxHeightByY = corner.isTop ? anchor.y : (1 - anchor.y)
        let maxWidthByHeight = maxHeightByY * aspect
        newWidth = min(newWidth, maxWidthByX, maxWidthByHeight)
        newWidth = max(newWidth, minWidth)
        let newHeight = newWidth / aspect

        // Place the rect extending from the anchor toward the dragged corner.
        let originX = corner.isLeft ? anchor.x - newWidth : anchor.x
        let originY = corner.isTop ? anchor.y - newHeight : anchor.y
        return NormalizedRect(x: originX, y: originY, width: newWidth, height: newHeight)
    }
}

/// The canvas alignment guides a dragged layer can snap to, in normalized
/// coordinates: the two edges, the center, and the thirds.
public enum SnapGuides {
    public static let lines: [Double] = [0, 1.0 / 3.0, 0.5, 2.0 / 3.0, 1]

    /// Snap a moving rect so its left/center/right (and top/middle/bottom) edges
    /// align to a canvas guide when within `threshold` (normalized distance).
    /// Returns the adjusted rect plus the guide lines that engaged, so the
    /// overlay can draw them.
    public static func snap(
        _ rect: NormalizedRect,
        threshold: Double
    ) -> (rect: NormalizedRect, vertical: [Double], horizontal: [Double]) {
        var result = rect
        var vGuides: [Double] = []
        var hGuides: [Double] = []

        // Horizontal axis: candidate anchors are the rect's left edge, center,
        // and right edge. Snap the best (closest within threshold) so that edge
        // lands exactly on a guide, shifting the whole rect.
        if let adjust = bestSnap(
            anchors: [rect.minX, rect.midX, rect.maxX],
            threshold: threshold
        ) {
            result.x += adjust.delta
            vGuides.append(adjust.line)
        }
        if let adjust = bestSnap(
            anchors: [rect.minY, rect.midY, rect.maxY],
            threshold: threshold
        ) {
            result.y += adjust.delta
            hGuides.append(adjust.line)
        }
        return (result.clampedTranslatedIntoUnit(), vGuides, hGuides)
    }

    /// Of every (anchor, guide) pair within threshold, the smallest shift, and
    /// the guide line it snaps to. nil if nothing is close enough.
    private static func bestSnap(
        anchors: [Double],
        threshold: Double
    ) -> (delta: Double, line: Double)? {
        var best: (delta: Double, line: Double)?
        for anchor in anchors {
            for line in lines {
                let delta = line - anchor
                if abs(delta) <= threshold, abs(delta) < abs(best?.delta ?? .infinity) {
                    best = (delta, line)
                }
            }
        }
        return best
    }
}
