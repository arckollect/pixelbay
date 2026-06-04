import CoreGraphics
import Foundation
import ImageIO
import PixelbayCompositor
import PixelbayCore

// Injectable seam (same shape as `WallpaperSource`) that turns a
// `WallpaperImageRef` into a render-ready CGImage. Kept as a closure so
// `PreviewCompositionBuilder.build` stays decoupled from where the bytes live:
// the app provides `.live`, wiring built-ins through the design-system bundle
// catalog and uploads through the project bundle. Tests can inject a stub.
public struct WallpaperImageProvider: Sendable {
    /// Given a wallpaper ref and the composition's output size, return a
    /// CGImage already center-cropped to the output aspect (so the compositor
    /// draws it full-screen with no distortion). Nil if it can't be loaded.
    public var provide: @Sendable (WallpaperImageRef, CGSize) -> CGImage?

    public init(provide: @escaping @Sendable (WallpaperImageRef, CGSize) -> CGImage?) {
        self.provide = provide
    }
}

public extension WallpaperImageProvider {
    /// Resolves built-in wallpapers through `builtinURL` (the app injects a
    /// lookup over the bundled catalog) and uploaded wallpapers through
    /// `bundleURL` + the ref's stored relative path. Loads via ImageIO and
    /// aspect-crops on a background thread — no main-actor / AppKit access, so
    /// it's safe to call from inside the nonisolated `build`.
    static func live(
        bundleURL: URL,
        builtinURL: @escaping @Sendable (String) -> URL?
    ) -> WallpaperImageProvider {
        WallpaperImageProvider { ref, outputSize in
            let url: URL?
            if let id = ref.builtinID {
                url = builtinURL(id)
            } else if let rel = ref.relativePath {
                url = bundleURL.appendingPathComponent(rel)
            } else {
                url = nil
            }
            guard let url,
                  let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
            else { return nil }
            return BackgroundImage.aspectCropped(image, toAspectOf: outputSize)
        }
    }
}
