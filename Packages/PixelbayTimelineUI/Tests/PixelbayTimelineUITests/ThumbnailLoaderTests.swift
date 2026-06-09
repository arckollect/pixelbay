import AppKit
@testable import PixelbayTimelineUI
import XCTest

final class ThumbnailLoaderTests: XCTestCase {
    func test_isDecodableImageData_rejectsCorruptBytes() {
        let corrupt = Data([0x50, 0x49, 0x58, 0x00, 0x01])

        XCTAssertFalse(ThumbnailLoader.isDecodableImageData(corrupt))
    }

    func test_isDecodableImageData_acceptsPNGBytes() throws {
        let image = NSImage(size: NSSize(width: 2, height: 2))
        image.lockFocus()
        NSColor.black.setFill()
        NSRect(x: 0, y: 0, width: 2, height: 2).fill()
        image.unlockFocus()
        let tiff = try XCTUnwrap(image.tiffRepresentation)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: tiff))
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))

        XCTAssertTrue(ThumbnailLoader.isDecodableImageData(png))
    }
}
