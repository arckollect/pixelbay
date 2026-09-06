import CoreGraphics
import XCTest
@testable import PixelbayCompositor

// `LayoutCalculator.aspectFillCropUV` — the centre-crop the render graph
// applies to the webcam so a native-aspect camera frame covers its slot
// (16:9 PiP, or the full screen rect during a talking head) without being
// stretched.
final class AspectFillCropTests: XCTestCase {

    func test_matchingAspect_isIdentity() {
        let crop = LayoutCalculator.aspectFillCropUV(
            sourceSize: CGSize(width: 1280, height: 720),
            destinationSize: CGSize(width: 320, height: 180)
        )
        XCTAssertEqual(crop, ResolvedLayout.identityUVTransform)
    }

    func test_widerSource_cropsSidesKeepsFullHeight() {
        // 16:9 camera into a 4:3 slot → keep height, sample the middle 75% of width.
        let crop = LayoutCalculator.aspectFillCropUV(
            sourceSize: CGSize(width: 1920, height: 1080),
            destinationSize: CGSize(width: 400, height: 300)
        )
        XCTAssertEqual(crop.x, 0.75, accuracy: 1e-5, "x scale = (4/3) / (16/9)")
        XCTAssertEqual(crop.y, 1, accuracy: 1e-6)
        XCTAssertEqual(crop.z, 0.125, accuracy: 1e-5, "centred: (1 - 0.75) / 2")
        XCTAssertEqual(crop.w, 0, accuracy: 1e-6)
    }

    func test_tallerSource_cropsTopAndBottomKeepsFullWidth() {
        // 4:3 camera into a 16:9 slot → keep width, sample the middle 75% of height.
        let crop = LayoutCalculator.aspectFillCropUV(
            sourceSize: CGSize(width: 1280, height: 960),
            destinationSize: CGSize(width: 1920, height: 1080)
        )
        XCTAssertEqual(crop.x, 1, accuracy: 1e-6)
        XCTAssertEqual(crop.y, 0.75, accuracy: 1e-5, "y scale = (4/3) / (16/9)")
        XCTAssertEqual(crop.z, 0, accuracy: 1e-6)
        XCTAssertEqual(crop.w, 0.125, accuracy: 1e-5)
    }

    func test_talkingHead_16x9CamIntoMacBookScreenRect_isCentredSideCrop() {
        // The reported case: a 16:9 webcam swapped onto a 16:10 screen rect
        // was being stretched. Now: full height, sides trimmed symmetrically.
        let crop = LayoutCalculator.aspectFillCropUV(
            sourceSize: CGSize(width: 1920, height: 1080),
            destinationSize: CGSize(width: 1728, height: 1080)
        )
        XCTAssertEqual(crop.y, 1, accuracy: 1e-6)
        XCTAssertLessThan(crop.x, 1)
        XCTAssertEqual(crop.z, (1 - crop.x) / 2, accuracy: 1e-6, "crop is centred")
        // Cropped source region keeps the destination's aspect exactly.
        let croppedAspect = (1920 * Double(crop.x)) / 1080
        XCTAssertEqual(croppedAspect, 1728.0 / 1080.0, accuracy: 1e-4)
    }

    func test_degenerateSizes_areIdentity() {
        XCTAssertEqual(
            LayoutCalculator.aspectFillCropUV(sourceSize: .zero, destinationSize: CGSize(width: 10, height: 10)),
            ResolvedLayout.identityUVTransform
        )
        XCTAssertEqual(
            LayoutCalculator.aspectFillCropUV(sourceSize: CGSize(width: 10, height: 10), destinationSize: CGSize(width: 0, height: 5)),
            ResolvedLayout.identityUVTransform
        )
    }
}

// `LayoutCalculator.aspectFitRect` — the letterbox the render graph applies
// to the screen layer so a clip whose shape differs from the layout's
// screen rect (an imported video after a screen recording) is never
// stretched.
final class AspectFitRectTests: XCTestCase {

    private let slot = LayerRect(origin: CGPoint(x: 100, y: 50), size: CGSize(width: 1600, height: 1000))  // 16:10

    func test_matchingAspect_returnsSlotUnchanged() {
        let fitted = LayoutCalculator.aspectFitRect(sourceSize: CGSize(width: 3200, height: 2000), in: slot)
        XCTAssertEqual(fitted, slot)
    }

    func test_widerSource_letterboxes_fullWidthCentredVertically() {
        // 16:9 imported video into the 16:10 slot → full width, 900 tall, 50pt bars.
        let fitted = LayoutCalculator.aspectFitRect(sourceSize: CGSize(width: 1920, height: 1080), in: slot)
        XCTAssertEqual(fitted.size.width, 1600, accuracy: 0.001)
        XCTAssertEqual(fitted.size.height, 900, accuracy: 0.001)
        XCTAssertEqual(fitted.origin.x, 100, accuracy: 0.001)
        XCTAssertEqual(fitted.origin.y, 100, accuracy: 0.001, "50 + (1000 - 900) / 2")
        XCTAssertEqual(fitted.midX, slot.midX, accuracy: 0.001)
        XCTAssertEqual(fitted.midY, slot.midY, accuracy: 0.001)
    }

    func test_tallerSource_pillarboxes_fullHeightCentredHorizontally() {
        // Portrait phone clip into the 16:10 slot → full height, narrow, centred.
        let fitted = LayoutCalculator.aspectFitRect(sourceSize: CGSize(width: 1080, height: 1920), in: slot)
        XCTAssertEqual(fitted.size.height, 1000, accuracy: 0.001)
        XCTAssertEqual(fitted.size.width, 562.5, accuracy: 0.001)
        XCTAssertEqual(fitted.midX, slot.midX, accuracy: 0.001)
        XCTAssertEqual(fitted.midY, slot.midY, accuracy: 0.001)
    }

    func test_fittedRect_keepsSourceAspectExactly() {
        let source = CGSize(width: 1280, height: 720)
        let fitted = LayoutCalculator.aspectFitRect(sourceSize: source, in: slot)
        XCTAssertEqual(fitted.size.width / fitted.size.height, source.width / source.height, accuracy: 1e-6)
    }

    func test_degenerateSizes_returnSlot() {
        XCTAssertEqual(LayoutCalculator.aspectFitRect(sourceSize: .zero, in: slot), slot)
        let emptySlot = LayerRect(origin: .zero, size: .zero)
        XCTAssertEqual(LayoutCalculator.aspectFitRect(sourceSize: CGSize(width: 16, height: 9), in: emptySlot), emptySlot)
    }
}
