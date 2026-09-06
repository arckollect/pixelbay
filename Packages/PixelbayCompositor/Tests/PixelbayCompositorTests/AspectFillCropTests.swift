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
