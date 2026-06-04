import Foundation
#if canImport(AppKit)
import AppKit
import ImageIO
#endif

// Built-in image wallpapers bundled with the app. Discovered at runtime from
// the package bundle so the set is *data-driven*: drop a new PNG into
// `Resources/Wallpapers/` and it appears in the gallery on the next build —
// no code change. The file's base name is its display name (e.g.
// `Night Dune.png` → "Night Dune").

public struct BuiltinWallpaper: Identifiable, Sendable, Equatable {
    /// Stable id == display name == file base name. Stored in the project's
    /// `WallpaperImageRef.builtinID`.
    public let id: String
    public let name: String
    public let url: URL
}

public enum WallpaperCatalog {
    /// All bundled wallpapers, sorted by name. Computed once.
    public static let builtins: [BuiltinWallpaper] = {
        let exts = ["png", "jpg", "jpeg", "heic"]
        var found: [BuiltinWallpaper] = []
        for ext in exts {
            let urls = Bundle.module.urls(forResourcesWithExtension: ext, subdirectory: "Wallpapers") ?? []
            for url in urls {
                let name = url.deletingPathExtension().lastPathComponent
                found.append(BuiltinWallpaper(id: name, name: name, url: url))
            }
        }
        return found.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }()

    /// URL for a built-in by its id. Used by the app's wallpaper image
    /// provider to resolve `WallpaperImageRef.builtinID` at render time.
    public static func url(forBuiltinID id: String) -> URL? {
        builtins.first { $0.id == id }?.url
    }
}

#if canImport(AppKit)
public extension WallpaperCatalog {
    /// Small downscaled thumbnail for a gallery swatch, decoded via ImageIO so
    /// we never hold a full multi-megapixel image in memory for a 40pt tile.
    /// Cached by URL. `maxPixel` is the longer edge in pixels. Main-actor (it's
    /// only called from SwiftUI) so the cache needs no extra synchronization.
    @MainActor
    static func thumbnail(for url: URL, maxPixel: Int = 256) -> NSImage? {
        let key = url.path as NSString
        if let cached = thumbnailCache.object(forKey: key) { return cached }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        let image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        thumbnailCache.setObject(image, forKey: key)
        return image
    }

    @MainActor
    private static let thumbnailCache = NSCache<NSString, NSImage>()
}
#endif
