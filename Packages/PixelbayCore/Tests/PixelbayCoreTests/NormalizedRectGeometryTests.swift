import XCTest
@testable import PixelbayCore

final class NormalizedRectGeometryTests: XCTestCase {

    // MARK: - Corners

    func test_corner_returnsExpectedPoints() {
        let r = NormalizedRect(x: 0.2, y: 0.3, width: 0.4, height: 0.5)
        XCTAssertEqual(r.corner(.topLeft).x, 0.2, accuracy: 1e-9)
        XCTAssertEqual(r.corner(.topLeft).y, 0.3, accuracy: 1e-9)
        XCTAssertEqual(r.corner(.bottomRight).x, 0.6, accuracy: 1e-9)
        XCTAssertEqual(r.corner(.bottomRight).y, 0.8, accuracy: 1e-9)
        XCTAssertEqual(RectCorner.topLeft.opposite, .bottomRight)
    }

    // MARK: - Translate + clamp

    func test_translated_movesAndStaysOnCanvas() {
        let r = NormalizedRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2)
        let moved = r.translated(dx: 0.1, dy: -0.1)
        XCTAssertEqual(moved.x, 0.5, accuracy: 1e-9)
        XCTAssertEqual(moved.y, 0.3, accuracy: 1e-9)
    }

    func test_translated_clampsAtEdges() {
        let r = NormalizedRect(x: 0.85, y: 0.85, width: 0.2, height: 0.2)
        let moved = r.translated(dx: 0.5, dy: 0.5)
        // Right/bottom edges pinned to 1.0 → origin at 0.8.
        XCTAssertEqual(moved.maxX, 1.0, accuracy: 1e-9)
        XCTAssertEqual(moved.maxY, 1.0, accuracy: 1e-9)
        XCTAssertEqual(moved.x, 0.8, accuracy: 1e-9)
    }

    // MARK: - Aspect-locked resize

    func test_resized_keepsAspectRatio() {
        let r = NormalizedRect(x: 0.1, y: 0.1, width: 0.4, height: 0.225) // 16:9
        // Drag the bottom-right corner outward; anchor is top-left (0.1, 0.1).
        let resized = r.resized(
            draggingCorner: .bottomRight,
            toX: 0.7, toY: 0.9,
            aspect: 16.0 / 9.0,
            minWidth: 0.05
        )
        XCTAssertEqual(resized.width / resized.height, 16.0 / 9.0, accuracy: 1e-6)
        // Anchor (top-left) stays pinned.
        XCTAssertEqual(resized.minX, 0.1, accuracy: 1e-9)
        XCTAssertEqual(resized.minY, 0.1, accuracy: 1e-9)
    }

    func test_resized_pinsOppositeCorner_whenDraggingTopLeft() {
        let r = NormalizedRect(x: 0.3, y: 0.3, width: 0.4, height: 0.4)
        let resized = r.resized(
            draggingCorner: .topLeft,
            toX: 0.1, toY: 0.1,
            aspect: 1,
            minWidth: 0.05
        )
        // Bottom-right anchor stays at (0.7, 0.7).
        XCTAssertEqual(resized.maxX, 0.7, accuracy: 1e-9)
        XCTAssertEqual(resized.maxY, 0.7, accuracy: 1e-9)
        XCTAssertEqual(resized.width, resized.height, accuracy: 1e-9) // 1:1
    }

    func test_resized_respectsMinWidth() {
        let r = NormalizedRect(x: 0.1, y: 0.1, width: 0.4, height: 0.4)
        // Drag bottom-right almost onto the anchor → would collapse; min kicks in.
        let resized = r.resized(
            draggingCorner: .bottomRight,
            toX: 0.1001, toY: 0.1001,
            aspect: 1,
            minWidth: 0.08
        )
        XCTAssertEqual(resized.width, 0.08, accuracy: 1e-9)
    }

    func test_resized_clampsInsideCanvas() {
        let r = NormalizedRect(x: 0.5, y: 0.5, width: 0.2, height: 0.2)
        // Drag bottom-right way past the edge; result must stay within [0,1].
        let resized = r.resized(
            draggingCorner: .bottomRight,
            toX: 2.0, toY: 2.0,
            aspect: 1,
            minWidth: 0.05
        )
        XCTAssertLessThanOrEqual(resized.maxX, 1.0 + 1e-9)
        XCTAssertLessThanOrEqual(resized.maxY, 1.0 + 1e-9)
        XCTAssertEqual(resized.minX, 0.5, accuracy: 1e-9) // anchor pinned
    }

    // MARK: - Snapping

    func test_snap_centersToCanvasCenter() {
        // Rect whose center is just off 0.5 should snap so its center lands on 0.5.
        let r = NormalizedRect(x: 0.46, y: 0.30, width: 0.10, height: 0.10) // midX 0.51
        let snapped = SnapGuides.snap(r, threshold: 0.02)
        XCTAssertEqual(snapped.rect.midX, 0.5, accuracy: 1e-9)
        XCTAssertTrue(snapped.vertical.contains(0.5))
    }

    func test_snap_edgeToCanvasEdge() {
        let r = NormalizedRect(x: 0.01, y: 0.4, width: 0.2, height: 0.2)
        let snapped = SnapGuides.snap(r, threshold: 0.02)
        XCTAssertEqual(snapped.rect.minX, 0.0, accuracy: 1e-9)
        XCTAssertTrue(snapped.vertical.contains(0.0))
    }

    func test_snap_noSnapWhenOutsideThreshold() {
        // Edges 0.38/0.46, center 0.42 — all > 0.02 from every guide
        // (0, 1/3, 0.5, 2/3, 1), so nothing snaps.
        let r = NormalizedRect(x: 0.38, y: 0.38, width: 0.08, height: 0.08)
        let snapped = SnapGuides.snap(r, threshold: 0.02)
        XCTAssertEqual(snapped.rect.x, 0.38, accuracy: 1e-9)
        XCTAssertEqual(snapped.rect.y, 0.38, accuracy: 1e-9)
        XCTAssertTrue(snapped.vertical.isEmpty)
        XCTAssertTrue(snapped.horizontal.isEmpty)
    }
}
