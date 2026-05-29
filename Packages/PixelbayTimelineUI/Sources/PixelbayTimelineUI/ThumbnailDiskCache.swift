import CryptoKit
import Foundation
import OSLog

private let log = Logger(subsystem: "com.pixelbay.PixelbayApp", category: "ThumbnailDiskCache")

// On-disk L2 cache for timeline thumbnails. Mirrors `WaveformDiskCache` but
// stores plain PNG bytes (the format AVAssetImageGenerator output is already
// encoded to) rather than a custom binary blob — a thumbnail is a few KB and
// PNG round-trips losslessly, so there's no payload to hand-pack.
//
// Filename is a deterministic SHA-256 over (path, mtime, size, seconds, w, h)
// truncated to 16 bytes — the same cross-process-stable scheme as the waveform
// cache (Swift's randomized Hashable can't be used for filenames). The asset
// signature (mtime+size) in the key means an edited/replaced source file
// misses rather than serving a stale frame.
//
// Sendable so the `ThumbnailLoader` actor can hold it as a `let`. Disk I/O
// blocks the actor during the call; acceptable — reads are a few KB and writes
// happen once per (asset, time, size).
struct ThumbnailDiskCache: Sendable {
    let directory: URL?

    init(directory: URL?) {
        self.directory = directory
        guard let directory else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// `~/Library/Caches/<bundle>/Thumbnails`. Nil only on platforms with no
    /// user caches dir (none of our targets); callers treat nil as "skip L2".
    static func defaultDirectory() -> URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("com.pixelbay.PixelbayApp/Thumbnails", isDirectory: true)
    }

    struct Key: Hashable, Sendable {
        let assetPath: String
        let assetMTime: Double
        let assetSize: Int64
        let seconds: Double
        let width: Int
        let height: Int

        var filename: String {
            let canonical = "\(assetPath)|\(assetMTime)|\(assetSize)|\(seconds)|\(width)x\(height)"
            let digest = SHA256.hash(data: Data(canonical.utf8))
            return digest.prefix(16).map { String(format: "%02x", $0) }.joined() + ".png"
        }
    }

    /// Returns cached PNG bytes if present. Any failure (missing file,
    /// unreadable) returns nil so the caller regenerates.
    func read(key: Key) -> Data? {
        guard let directory else { return nil }
        return try? Data(contentsOf: directory.appendingPathComponent(key.filename))
    }

    /// Writes PNG bytes atomically. Best-effort — a write failure is logged
    /// and swallowed (the tile still renders from the in-memory L1).
    func write(data: Data, key: Key) {
        guard let directory else { return }
        let url = directory.appendingPathComponent(key.filename)
        do {
            try data.write(to: url, options: [.atomic])
        } catch {
            log.error("thumbnail cache write failed: \(String(describing: error), privacy: .public)")
        }
    }
}

extension ThumbnailDiskCache {
    /// `(mtime, size)` asset signature for the cache key — identical scheme
    /// to `WaveformDiskCache.assetSignature`. Nil if the asset can't be
    /// stat-ed (caller skips L2).
    static func assetSignature(for url: URL) -> (mtime: Double, size: Int64)? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.standardizedFileURL.path) else {
            return nil
        }
        let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        return (mtime, size)
    }
}
