import XCTest
import SwiftUI
import AppKit
@testable import PixelbayDesignSystem

final class HexColorTests: XCTestCase {
    func testSixDigitHexParsesToExpectedComponents() {
        let c = NSColor(hex: "#FF8040").usingColorSpace(.sRGB)!
        XCTAssertEqual(c.redComponent, 1.0, accuracy: 0.005)
        XCTAssertEqual(c.greenComponent, 128.0 / 255.0, accuracy: 0.005)
        XCTAssertEqual(c.blueComponent, 64.0 / 255.0, accuracy: 0.005)
        XCTAssertEqual(c.alphaComponent, 1.0, accuracy: 0.005)
    }

    func testEightDigitHexParsesAlpha() {
        let c = NSColor(hex: "#00000080").usingColorSpace(.sRGB)!
        XCTAssertEqual(c.alphaComponent, 128.0 / 255.0, accuracy: 0.005)
    }

    func testShorthandHexExpands() {
        let c = NSColor(hex: "#f00").usingColorSpace(.sRGB)!
        XCTAssertEqual(c.redComponent, 1.0, accuracy: 0.005)
        XCTAssertEqual(c.greenComponent, 0.0, accuracy: 0.005)
        XCTAssertEqual(c.blueComponent, 0.0, accuracy: 0.005)
    }

    func testLeadingHashOptional() {
        let withHash = NSColor(hex: "#262624").usingColorSpace(.sRGB)!
        let without = NSColor(hex: "262624").usingColorSpace(.sRGB)!
        XCTAssertEqual(withHash.redComponent, without.redComponent, accuracy: 0.001)
    }

    func testInvalidHexFallsBackToMagenta() {
        let c = NSColor(hex: "nonsense").usingColorSpace(.sRGB)!
        XCTAssertEqual(c.redComponent, 1.0, accuracy: 0.005)
        XCTAssertEqual(c.greenComponent, 0.0, accuracy: 0.005)
        XCTAssertEqual(c.blueComponent, 1.0, accuracy: 0.005)
    }

    func testTokensAreDistinct() {
        // Sanity: a couple of tokens resolve to different colours (catches a
        // copy-paste that points two tokens at the same hex).
        XCTAssertNotEqual(Theme.NSColor.bgBase, Theme.NSColor.accent)
        XCTAssertNotEqual(Theme.NSColor.trackVideo, Theme.NSColor.trackMic)
    }
}
