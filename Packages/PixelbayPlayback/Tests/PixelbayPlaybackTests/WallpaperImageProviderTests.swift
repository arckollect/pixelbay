import CoreGraphics
import Foundation
import ImageIO
import PixelbayCore
import UniformTypeIdentifiers
@testable import PixelbayPlayback
import XCTest

final class WallpaperImageProviderTests: XCTestCase {
    /// Writes a small opaque-white PNG to a unique temp file and returns its URL.
    private func writeTempPNG(width: Int = 32, height: Int = 32) throws -> URL {
        let bytesPerRow = width * 4
        let pixels = [UInt8](repeating: 255, count: width * height * 4)
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        let dataProvider = CGDataProvider(data: Data(pixels) as CFData)!
        let img = CGImage(
            width: width, height: height,
            bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: dataProvider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        )!
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).png")
        let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, img, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return url
    }

    /// The decode cache memoizes per (wallpaper identity, output size): a repeat
    /// call returns the SAME CGImage instance (without the cache, each call
    /// re-decodes + re-crops into a fresh instance), and a different output size
    /// is a cache miss.
    func test_live_memoizesDecodedImage_perRefAndSize() throws {
        let url = try writeTempPNG()
        defer { try? FileManager.default.removeItem(at: url) }
        // Unique id so the process-wide cache can't collide with another test.
        let id = "test-\(UUID().uuidString)"
        let provider = WallpaperImageProvider.live(
            bundleURL: FileManager.default.temporaryDirectory,
            builtinURL: { $0 == id ? url : nil }
        )
        let ref = WallpaperImageRef.builtin(id: id, name: "Test")

        let landscape = CGSize(width: 1920, height: 1080)
        let first = try XCTUnwrap(provider.provide(ref, landscape))
        let second = try XCTUnwrap(provider.provide(ref, landscape))
        XCTAssertTrue(first === second, "same ref + size should return the cached instance")

        // Different output aspect → different crop → distinct cached instance.
        let portrait = CGSize(width: 1080, height: 1920)
        let third = try XCTUnwrap(provider.provide(ref, portrait))
        XCTAssertFalse(first === third, "a different output size is a cache miss")
    }

    func test_live_returnsNil_whenRefResolvesToNoURL() {
        let provider = WallpaperImageProvider.live(
            bundleURL: FileManager.default.temporaryDirectory,
            builtinURL: { _ in nil }
        )
        let ref = WallpaperImageRef.builtin(id: "missing", name: "Missing")
        XCTAssertNil(provider.provide(ref, CGSize(width: 1920, height: 1080)))
    }
}
