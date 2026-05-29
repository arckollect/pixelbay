#if canImport(AVFoundation)
import AVFoundation
import AppKit
import CoreGraphics
import Foundation
import OSLog

private let log = Logger(subsystem: "com.pixelbay.PixelbayApp", category: "ThumbnailLoader")

// Decodes a single video frame from an asset at a given time and reduces it
// to a small PNG suitable for a timeline clip strip. Mirrors WaveformLoader's
// two-layer caching 1-for-1:
//
//   L1 — in-memory LRU, keyed by (path, seconds, width, height). Bounded at
//        256 tiles so a long timeline scrubbed at multiple zooms can't grow
//        memory without bound. `flushMemoryCache()` lets the app drop L1 on a
//        memory-pressure warning.
//   L2 — on-disk PNG cache (`ThumbnailDiskCache`), keyed by the asset
//        signature (path+mtime+size) plus (seconds, width, height). Survives
//        relaunch so reopening a project is FS reads, not AVAssetImageGenerator
//        passes.
//
// Order: L1 → L2 → AVAssetImageGenerator; a hit at any layer populates the
// layers above it. `cacheDirectory: nil` disables L2 (tests).
//
// Returns PNG `Data` (Sendable) rather than `CGImage` so the result crosses
// the actor boundary cleanly under Swift 6 strict concurrency; the caller
// decodes to a CGImage on the main actor for the CALayer's `contents`. PNG is
// also the on-disk format, so no extra round-trip.
public actor ThumbnailLoader {
    public enum LoadError: Error, LocalizedError {
        case noVideoTrack(URL)
        case generationFailed(String)
        case encodeFailed

        public var errorDescription: String? {
            switch self {
            case .noVideoTrack(let url): return "No video track in \(url.lastPathComponent)"
            case .generationFailed(let message): return "Thumbnail generate: \(message)"
            case .encodeFailed: return "Thumbnail PNG encode failed"
            }
        }
    }

    private struct CacheKey: Hashable {
        let path: String
        let seconds: Double
        let width: Int
        let height: Int
    }

    private var cache: [CacheKey: Data] = [:]
    /// Least-recently-used ordering; most-recently-touched key is last.
    private var lru: [CacheKey] = []
    private let l1Capacity = 256
    private let diskCache: ThumbnailDiskCache

    public init() {
        self.init(cacheDirectory: ThumbnailDiskCache.defaultDirectory())
    }

    public init(cacheDirectory: URL?) {
        self.diskCache = ThumbnailDiskCache(directory: cacheDirectory)
    }

    /// Drops the in-memory L1 cache (L2 disk survives). Wire to a
    /// memory-pressure source from the app if desired.
    public func flushMemoryCache() {
        cache.removeAll(keepingCapacity: false)
        lru.removeAll(keepingCapacity: false)
    }

    /// Returns PNG bytes for the frame at `atSeconds`, scaled to fit
    /// `targetSize`. L1 (memory) → L2 (disk) → AVAssetImageGenerator.
    public func thumbnail(
        forAssetAt url: URL,
        atSeconds: Double,
        targetSize: CGSize
    ) async throws -> Data {
        let width = Swift.max(1, Int(targetSize.width.rounded()))
        let height = Swift.max(1, Int(targetSize.height.rounded()))
        let roundedSeconds = (atSeconds * 1000).rounded() / 1000
        let key = CacheKey(
            path: url.standardizedFileURL.path,
            seconds: roundedSeconds,
            width: width,
            height: height
        )
        if let hit = cache[key] {
            touch(key)
            return hit
        }

        let diskKey = ThumbnailDiskCache.assetSignature(for: url).map { sig in
            ThumbnailDiskCache.Key(
                assetPath: key.path,
                assetMTime: sig.mtime,
                assetSize: sig.size,
                seconds: roundedSeconds,
                width: width,
                height: height
            )
        }
        if let diskKey, let data = diskCache.read(key: diskKey) {
            store(key, data)
            return data
        }

        let asset = AVURLAsset(url: url)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        guard !videoTracks.isEmpty else { throw LoadError.noVideoTrack(url) }

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        // Exact frame at the requested time — no tolerance — so adjacent
        // tiles on a clip read as distinct moments, not the same I-frame.
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        // Cap the decoded bitmap to the on-screen tile size (×2 for retina)
        // so we don't decompress a 4K frame to draw an 80pt strip.
        generator.maximumSize = CGSize(width: CGFloat(width) * 2, height: CGFloat(height) * 2)

        let assetDuration = try await asset.load(.duration)
        let durationSeconds = CMTimeGetSeconds(assetDuration)
        // Clamp inside the asset; pull back slightly from the very end so a
        // request at exactly duration doesn't fail.
        let clamped = Swift.max(0, Swift.min(roundedSeconds, Swift.max(0, durationSeconds - 0.05)))
        let time = CMTime(seconds: clamped, preferredTimescale: 600)

        let cgImage: CGImage
        do {
            let result = try await generator.image(at: time)
            cgImage = result.image
        } catch {
            throw LoadError.generationFailed(error.localizedDescription)
        }

        guard let data = Self.pngData(from: cgImage) else {
            throw LoadError.encodeFailed
        }
        store(key, data)
        if let diskKey {
            diskCache.write(data: data, key: diskKey)
        }
        return data
    }

    // MARK: - L1 LRU bookkeeping

    private func store(_ key: CacheKey, _ data: Data) {
        cache[key] = data
        touch(key)
        while lru.count > l1Capacity, let evict = lru.first {
            lru.removeFirst()
            cache[evict] = nil
        }
    }

    private func touch(_ key: CacheKey) {
        if let idx = lru.firstIndex(of: key) { lru.remove(at: idx) }
        lru.append(key)
    }

    // MARK: - Encode

    private static func pngData(from cgImage: CGImage) -> Data? {
        let rep = NSBitmapImageRep(cgImage: cgImage)
        return rep.representation(using: .png, properties: [:])
    }
}
#endif
