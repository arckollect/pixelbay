import CoreGraphics
import Foundation
import PixelbayCore
@testable import PixelbayPlayback
import XCTest

final class WallpaperSourceTests: XCTestCase {
    private let red = RGBColor(r: 0.95, g: 0.05, b: 0.10)
    private let blue = RGBColor(r: 0.10, g: 0.20, b: 0.95)

    func test_resolve_substitutesGradient_whenBackgroundIsSystemWallpaper() {
        let preset = LayoutPreset(background: .systemWallpaper(fallback: .black))
        let source = WallpaperSource(sampleBackground: { [red, blue] in
            WallpaperSample(top: red, bottom: blue)
        })

        let resolved = source.resolve(preset)
        XCTAssertEqual(resolved.background, .gradient(from: red, to: blue))
    }

    func test_resolve_keepsFallback_whenShimReturnsNil() {
        let preset = LayoutPreset(background: .systemWallpaper(fallback: red))
        let source = WallpaperSource(sampleBackground: { nil })

        let resolved = source.resolve(preset)
        XCTAssertEqual(resolved.background, .systemWallpaper(fallback: red))
    }

    func test_resolve_leavesSolidAndGradientUntouched() {
        let solid = LayoutPreset(background: .solid(color: red))
        let gradient = LayoutPreset(background: .gradient(from: red, to: blue))
        let source = WallpaperSource(sampleBackground: {
            // Should never be consulted for non-`.systemWallpaper` cases.
            XCTFail("shim invoked for non-systemWallpaper background")
            return nil
        })

        XCTAssertEqual(source.resolve(solid).background, solid.background)
        XCTAssertEqual(source.resolve(gradient).background, gradient.background)
    }

    func test_resolve_leavesNoneUntouched() {
        let preset = LayoutPreset(background: .none)
        let source = WallpaperSource(sampleBackground: {
            XCTFail("shim invoked for `.none` background")
            return nil
        })
        XCTAssertEqual(source.resolve(preset).background, .none)
    }

    #if canImport(AppKit)
    func test_sampleImage_returnsDistinctTopAndBottom_forSplitImage() throws {
        // Synthesise a 64×64 image with the top half pure red, bottom half
        // pure blue. The sampler should resolve top→red, bottom→blue.
        let width = 64
        let height = 64
        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            let isTopHalfOfImage = y < height / 2
            for x in 0..<width {
                let i = (y * width + x) * 4
                if isTopHalfOfImage {
                    pixels[i] = 255       // R
                    pixels[i + 1] = 0     // G
                    pixels[i + 2] = 0     // B
                } else {
                    pixels[i] = 0
                    pixels[i + 1] = 0
                    pixels[i + 2] = 255
                }
                pixels[i + 3] = 255
            }
        }
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        let provider = CGDataProvider(data: Data(pixels) as CFData)!
        let img = CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )!

        let sample = try XCTUnwrap(WallpaperSource.sampleImage(img))
        XCTAssertGreaterThan(sample.top.r, 0.9)
        XCTAssertLessThan(sample.top.b, 0.1)
        XCTAssertGreaterThan(sample.bottom.b, 0.9)
        XCTAssertLessThan(sample.bottom.r, 0.1)
    }
    #endif
}
