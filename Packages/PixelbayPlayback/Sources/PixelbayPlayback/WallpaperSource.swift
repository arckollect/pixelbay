#if canImport(CoreGraphics) && canImport(ImageIO)
import CoreGraphics
import Foundation
import ImageIO
import PixelbayCore
#if canImport(AppKit)
import AppKit
#endif

// Sendable seam over `NSWorkspace.shared.desktopImageURL(...)` + CGImage
// sampling. Same shape as `PixelbayPermissions.PermissionProbe`
// (HANDOFF §6.1): every actual AppKit / CG call goes through a closure
// here; tests inject canned values so `WallpaperSource.resolve(_:)` can
// be exercised without a live `NSWorkspace`.
//
// The `live` value below is the only place that touches NSWorkspace /
// NSScreen. The compositor architecture (LayerLayout.swift's
// `resolveBackground`) leaves `.systemWallpaper` to the app boundary;
// this shim is what the app uses to convert the user's desktop image

// into a gradient that the existing background pipeline can render —
// no new shader / pipeline state needed at v0.1.
public struct WallpaperSource: Sendable {
    public var sampleBackground: @Sendable () -> WallpaperSample?

    public init(sampleBackground: @escaping @Sendable () -> WallpaperSample?) {
        self.sampleBackground = sampleBackground
    }
}

public struct WallpaperSample: Sendable, Equatable {
    public var top: PixelbayCore.RGBColor
    public var bottom: PixelbayCore.RGBColor

    public init(top: PixelbayCore.RGBColor, bottom: PixelbayCore.RGBColor) {
        self.top = top
        self.bottom = bottom
    }
}

extension WallpaperSource {
    /// Returns a new `LayoutPreset` where any `.systemWallpaper(fallback:)`
    /// background has been resolved to a `.gradient(top, bottom)` using the
    /// shim's sample. If the shim returns nil (no main screen, no wallpaper
    /// URL, unreadable image), the preset is returned unchanged so the
    /// compositor's existing `.systemWallpaper` → `.solid(fallback)`
    /// fallback in `LayoutCalculator.resolveBackground` still applies.
    public func resolve(_ preset: LayoutPreset) -> LayoutPreset {
        guard case .systemWallpaper = preset.background else { return preset }
        guard let sample = sampleBackground() else { return preset }
        var next = preset
        next.background = .gradient(from: sample.top, to: sample.bottom)
        return next
    }
}

#if canImport(AppKit)
extension WallpaperSource {
    /// OS-backed sampler. Reads the main screen's wallpaper URL and
    /// averages the top and bottom halves of a 32×32 downscale into two
    /// `PixelbayCore.RGBColor`s.
    ///
    /// Both PreviewCompositionBuilder call sites in the app target are
    /// already main-actor (SwiftUI .task in ProjectView / PostCaptureView,
    /// ExportSheet.runExport on a View), so the `@MainActor`-isolated
    /// `NSScreen.main` access is reached via `MainActor.assumeIsolated`.
    public static let live = WallpaperSource(sampleBackground: {
        // `resolve(_:)` is invoked from inside `PreviewCompositionBuilder.build`
        // — a `nonisolated` async function, so even though its callers
        // (`PreviewPlayer.load`, ExportSheet, PostCaptureView) are @MainActor,
        // the awaited `build` body runs OFF the main actor on the cooperative
        // pool. `NSScreen.main` / `NSWorkspace` are main-actor-isolated, so we
        // must hop to main to sample them; calling `assumeIsolated` directly
        // off-main fatal-errors. (This path was unreachable until the Layout
        // tab's "Desktop" swatch let the user pick `.systemWallpaper`.)
        func sampleOnMain() -> WallpaperSample? {
            MainActor.assumeIsolated { loadLiveSample() }
        }
        if Thread.isMainThread {
            return sampleOnMain()
        }
        // Safe: the calling @MainActor task is suspended at its `await`, so the
        // main runloop is free to service this — no deadlock.
        return DispatchQueue.main.sync(execute: sampleOnMain)
    })

    @MainActor
    private static func loadLiveSample() -> WallpaperSample? {
        guard let screen = NSScreen.main,
              let url = NSWorkspace.shared.desktopImageURL(for: screen)
        else { return nil }
        return sampleImage(at: url)
    }

    static func sampleImage(at url: URL) -> WallpaperSample? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil)
        else { return nil }
        return sampleImage(img)
    }

    static func sampleImage(_ img: CGImage) -> WallpaperSample? {
        let thumb = 32
        let bytesPerRow = thumb * 4
        var pixels = [UInt8](repeating: 0, count: thumb * thumb * 4)
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
            return nil
        }
        let info = CGImageAlphaInfo.premultipliedLast.rawValue
        let ctx = pixels.withUnsafeMutableBufferPointer { buf -> CGContext? in
            CGContext(
                data: buf.baseAddress,
                width: thumb,
                height: thumb,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: colorSpace,
                bitmapInfo: info
            )
        }
        guard let ctx else { return nil }
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: thumb, height: thumb))

        // CGContext bitmap data is laid out row-0-at-top even though
        // Quartz's drawing coordinate system is bottom-up — the
        // CGContext.draw flip is handled during rendering, not in the
        // pixel buffer's row order.
        let half = thumb / 2
        var topR = 0, topG = 0, topB = 0
        var bottomR = 0, bottomG = 0, bottomB = 0
        let count = half * thumb
        for y in 0..<half {
            for x in 0..<thumb {
                let i = (y * thumb + x) * 4
                topR += Int(pixels[i])
                topG += Int(pixels[i + 1])
                topB += Int(pixels[i + 2])
            }
        }
        for y in half..<thumb {
            for x in 0..<thumb {
                let i = (y * thumb + x) * 4
                bottomR += Int(pixels[i])
                bottomG += Int(pixels[i + 1])
                bottomB += Int(pixels[i + 2])
            }
        }
        let scale = 1.0 / Double(count * 255)
        let top = PixelbayCore.RGBColor(
            r: Double(topR) * scale,
            g: Double(topG) * scale,
            b: Double(topB) * scale
        )
        let bottom = PixelbayCore.RGBColor(
            r: Double(bottomR) * scale,
            g: Double(bottomG) * scale,
            b: Double(bottomB) * scale
        )
        return WallpaperSample(top: top, bottom: bottom)
    }
}
#endif

#endif
