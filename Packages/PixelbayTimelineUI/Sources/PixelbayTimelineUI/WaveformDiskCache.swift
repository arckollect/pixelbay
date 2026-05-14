import CryptoKit
import Foundation
import OSLog

private let log = Logger(subsystem: "com.pixelbay.PixelbayApp", category: "WaveformDiskCache")

// On-disk L2 cache for WaveformPeaks. Format is a tiny raw binary
// (~8 bytes per bucket plus a 36-byte header) instead of JSON / plist
// so re-opening a project with hours of cached audio is dominated by
// FS reads, not Codable.
//
// Layout (little-endian, all platforms Apple ships are LE):
//
//   offset  size  field
//   0       4     magic 'PIXW'
//   4       2     version (u16, currently 1)
//   6       2     reserved
//   8       8     asset mtime (Double, seconds since 1970)
//   16      8     startSeconds (Double)
//   24      8     durationSeconds (Double)
//   32      4     buckets (u32)
//   36      ...   buckets × Float32 min[], then buckets × Float32 max[]
//
// On read we re-validate every header field against the expected key
// — defends against SHA-256 collisions, file truncation, and stale
// caches that survived an mtime change but landed in a filename that
// happens to collide. On any mismatch we treat the file as a miss
// (caller falls back to AVAssetReader).
//
// FileManager + Data calls below are thread-safe; the struct is
// Sendable so the surrounding `WaveformLoader` actor can hold it as a
// `let` without an extra hop. Disk I/O still blocks the actor during
// the call; that's acceptable for v0.1 (reads are kilobytes; writes
// happen once per (asset, range, zoom) combination).
struct WaveformDiskCache: Sendable {
    let directory: URL?

    private static let magic: [UInt8] = [0x50, 0x49, 0x58, 0x57]  // 'PIXW'
    private static let version: UInt16 = 1
    private static let headerSize = 36

    init(directory: URL?) {
        self.directory = directory
        guard let directory else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// `URL` for the default cache dir (`~/Library/Caches/<bundle>/waveforms`).
    /// Returns `nil` only on platforms with no user caches dir, which
    /// none of our supported targets are; callers should still treat
    /// `nil` as "skip the disk layer."
    static func defaultDirectory() -> URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("com.pixelbay.PixelbayApp/waveforms", isDirectory: true)
    }

    /// Cache key — captured as a value so the same key can be passed
    /// to both `read` and `write` without recomputing the digest.
    struct Key: Hashable, Sendable {
        let assetPath: String
        let assetMTime: Double
        let assetSize: Int64
        let startSeconds: Double
        let durationSeconds: Double
        let buckets: Int

        /// Deterministic 32-hex filename. We need cross-process stability,
        /// so Swift's randomized Hashable is unusable here — use SHA-256
        /// truncated to 16 bytes (collision probability negligible
        /// before the cache dir runs out of inodes anyway).
        var filename: String {
            let canonical = "\(assetPath)|\(assetMTime)|\(assetSize)|\(startSeconds)|\(durationSeconds)|\(buckets)"
            let digest = SHA256.hash(data: Data(canonical.utf8))
            return digest.prefix(16).map { String(format: "%02x", $0) }.joined() + ".wfcache"
        }
    }

    /// Loads a cached peaks blob if present, valid, and matches the
    /// expected key fields. Any failure mode (missing file, bad magic,
    /// wrong version, header / payload size mismatch, expected-key
    /// fields drifted from what's stored) returns `nil` so the caller
    /// falls back to re-decoding.
    func read(key: Key) -> WaveformPeaks? {
        guard let directory else { return nil }
        let url = directory.appendingPathComponent(key.filename)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return decode(data, expectedKey: key)
    }

    /// Writes peaks atomically. Errors are logged and swallowed —
    /// caching is best-effort; a write failure shouldn't propagate to
    /// the user (the waveform still renders from the in-memory L1).
    func write(peaks: WaveformPeaks, key: Key) {
        guard let directory else { return }
        let url = directory.appendingPathComponent(key.filename)
        let data = encode(peaks: peaks, key: key)
        do {
            try data.write(to: url, options: [.atomic])
        } catch {
            log.error("waveform cache write failed: \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: - Encode / decode

    func encode(peaks: WaveformPeaks, key: Key) -> Data {
        var data = Data()
        data.reserveCapacity(Self.headerSize + 8 * peaks.bucketCount)
        data.append(contentsOf: Self.magic)
        appendLE(&data, Self.version)
        appendLE(&data, UInt16(0))  // reserved
        appendBits(&data, key.assetMTime)
        appendBits(&data, key.startSeconds)
        appendBits(&data, key.durationSeconds)
        appendLE(&data, UInt32(peaks.bucketCount))
        peaks.min.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            data.append(contentsOf: raw)
        }
        peaks.max.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            data.append(contentsOf: raw)
        }
        return data
    }

    func decode(_ data: Data, expectedKey: Key) -> WaveformPeaks? {
        guard data.count >= Self.headerSize else { return nil }
        // Magic + version.
        guard data[0] == Self.magic[0],
              data[1] == Self.magic[1],
              data[2] == Self.magic[2],
              data[3] == Self.magic[3] else { return nil }
        let version: UInt16 = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 4, as: UInt16.self) }
        guard version == Self.version else { return nil }
        // Header fields.
        let mtime: Double = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 8, as: Double.self) }
        let start: Double = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 16, as: Double.self) }
        let dur: Double = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 24, as: Double.self) }
        let buckets: Int = data.withUnsafeBytes { Int($0.loadUnaligned(fromByteOffset: 32, as: UInt32.self)) }
        // Re-validate that the file's stored fields match what the
        // caller asked for. Catches the rare SHA-256 collision case
        // and any future format drift the version bump didn't catch.
        guard mtime == expectedKey.assetMTime,
              start == expectedKey.startSeconds,
              dur == expectedKey.durationSeconds,
              buckets == expectedKey.buckets else { return nil }
        // Payload size: buckets × 4B min + buckets × 4B max.
        let payloadBytes = buckets * MemoryLayout<Float>.size * 2
        guard data.count == Self.headerSize + payloadBytes else { return nil }
        var minArr = [Float](repeating: 0, count: buckets)
        var maxArr = [Float](repeating: 0, count: buckets)
        let minStart = Self.headerSize
        let maxStart = minStart + buckets * MemoryLayout<Float>.size
        _ = minArr.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) -> Int in
            data.copyBytes(to: raw, from: minStart..<maxStart)
        }
        _ = maxArr.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) -> Int in
            data.copyBytes(to: raw, from: maxStart..<(maxStart + buckets * MemoryLayout<Float>.size))
        }
        return WaveformPeaks(min: minArr, max: maxArr)
    }

    // MARK: - Encoding helpers
    // Lightweight append-bytes helpers so encode() reads top-to-bottom
    // as field-by-field; no intermediate Data fragments.

    private func appendLE(_ data: inout Data, _ value: UInt16) {
        var v = value.littleEndian
        withUnsafeBytes(of: &v) { data.append(contentsOf: $0) }
    }

    private func appendLE(_ data: inout Data, _ value: UInt32) {
        var v = value.littleEndian
        withUnsafeBytes(of: &v) { data.append(contentsOf: $0) }
    }

    private func appendBits(_ data: inout Data, _ value: Double) {
        var v = value
        withUnsafeBytes(of: &v) { data.append(contentsOf: $0) }
    }
}

extension WaveformDiskCache {
    /// `(mtime, size)` pair used as the asset signature in the cache key.
    /// Returns `nil` if the asset can't be stat-ed (missing file,
    /// permissions); the caller treats this as "skip the disk cache."
    static func assetSignature(for url: URL) -> (mtime: Double, size: Int64)? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.standardizedFileURL.path) else {
            return nil
        }
        let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        return (mtime, size)
    }
}
