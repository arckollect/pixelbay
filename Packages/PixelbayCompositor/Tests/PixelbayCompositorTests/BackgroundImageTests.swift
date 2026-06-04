import CoreGraphics
import XCTest
@testable import PixelbayCompositor

final class BackgroundImageTests: XCTestCase {
    private let output = CGSize(width: 1920, height: 1080)   // 16:9

    func test_cropRect_widerImage_trimsSidesToOutputAspect() {
        // 2:1 image is wider than 16:9 → crop width, keep full height.
        let rect = BackgroundImage.cropRect(imageWidth: 3072, imageHeight: 1536, outputSize: output)
        XCTAssertEqual(rect.height, 1536, accuracy: 1)
        XCTAssertLessThan(rect.width, 3072)
        XCTAssertEqual(rect.width / rect.height, 16.0 / 9.0, accuracy: 0.01)
        // Centered.
        XCTAssertEqual(rect.midX, 1536, accuracy: 1)
    }

    func test_cropRect_tallerImage_trimsTopBottomToOutputAspect() {
        // Square image is taller than 16:9 → crop height, keep full width.
        let rect = BackgroundImage.cropRect(imageWidth: 1000, imageHeight: 1000, outputSize: output)
        XCTAssertEqual(rect.width, 1000, accuracy: 1)
        XCTAssertLessThan(rect.height, 1000)
        XCTAssertEqual(rect.width / rect.height, 16.0 / 9.0, accuracy: 0.01)
        XCTAssertEqual(rect.midY, 500, accuracy: 1)
    }

    func test_cropRect_matchingAspect_isFullImage() {
        let rect = BackgroundImage.cropRect(imageWidth: 1920, imageHeight: 1080, outputSize: output)
        XCTAssertEqual(rect.width, 1920, accuracy: 1)
        XCTAssertEqual(rect.height, 1080, accuracy: 1)
        XCTAssertEqual(rect.origin.x, 0, accuracy: 1)
        XCTAssertEqual(rect.origin.y, 0, accuracy: 1)
    }

    func test_cropRect_zeroSizes_returnFullImageSafely() {
        let rect = BackgroundImage.cropRect(imageWidth: 0, imageHeight: 0, outputSize: output)
        XCTAssertEqual(rect.width, 0)
        XCTAssertEqual(rect.height, 0)
    }
}
