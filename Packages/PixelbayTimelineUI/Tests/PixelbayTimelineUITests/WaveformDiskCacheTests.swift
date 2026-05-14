@testable import PixelbayTimelineUI
import Foundation
import XCTest

/// Disk-cache round-trip + invalidation. The live AVAssetReader path
/// stays out of scope (fragile in test bundles) — these tests exercise
/// the encoder / decoder / file IO directly with synthetic peaks.
final class WaveformDiskCacheTests: XCTestCase {
    private var tempDir: URL!
    private var cache: WaveformDiskCache!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("WaveformDiskCacheTests-\(UUID().uuidString)", isDirectory: true)
        cache = WaveformDiskCache(directory: tempDir)
    }

    override func tearDownWithError() throws {
        if let tempDir, FileManager.default.fileExists(atPath: tempDir.path) {
            try FileManager.default.removeItem(at: tempDir)
        }
        try super.tearDownWithError()
    }

    private func makeKey(
        path: String = "/tmp/asset.caf",
        mtime: Double = 1_700_000_000.0,
        size: Int64 = 1_024_000,
        startSeconds: Double = 0,
        durationSeconds: Double = 10,
        buckets: Int = 32
    ) -> WaveformDiskCache.Key {
        WaveformDiskCache.Key(
            assetPath: path,
            assetMTime: mtime,
            assetSize: size,
            startSeconds: startSeconds,
            durationSeconds: durationSeconds,
            buckets: buckets
        )
    }

    private func makePeaks(count: Int = 32) -> WaveformPeaks {
        // Deterministic, exercises both polarities + non-zero magnitudes.
        var minArr = [Float](); var maxArr = [Float]()
        for i in 0..<count {
            let phase = Float(i) * 0.1
            minArr.append(-0.5 - phase * 0.001)
            maxArr.append( 0.6 + phase * 0.002)
        }
        return WaveformPeaks(min: minArr, max: maxArr)
    }

    func test_writeThenRead_roundTrips() {
        // Buckets stored in the file's header must match the caller's
        // expected key, so the bucket count in `peaks` and `key` has
        // to agree.
        let key = makeKey(buckets: 64)
        let peaks = makePeaks(count: 64)
        cache.write(peaks: peaks, key: key)
        let hit = cache.read(key: key)
        XCTAssertEqual(hit, peaks)
    }

    func test_writeThenRead_zeroBuckets_roundTrips() {
        let key = makeKey(buckets: 0)
        let peaks = WaveformPeaks(min: [], max: [])
        cache.write(peaks: peaks, key: key)
        // The encode/decode pair handles the buckets=0 / empty payload
        // path; readback should equal what was written.
        XCTAssertEqual(cache.read(key: key), peaks)
    }

    func test_read_missingFile_returnsNil() {
        let key = makeKey(path: "/tmp/never-written.caf")
        XCTAssertNil(cache.read(key: key))
    }

    func test_read_keyMismatch_returnsNil() {
        // SHA-256 collision defence + asset-replacement invalidation.
        // Write with one mtime; read with a different mtime → miss.
        let writeKey = makeKey(mtime: 1_700_000_000)
        let readKey = makeKey(mtime: 1_700_000_999)  // asset re-saved
        cache.write(peaks: makePeaks(), key: writeKey)
        // Different mtime → different filename in our key scheme, so this
        // is a clean miss because the file at the read-key digest doesn't
        // exist. Confirms the key includes mtime.
        XCTAssertNil(cache.read(key: readKey))
    }

    func test_read_corruptHeader_returnsNil() {
        let key = makeKey()
        let url = tempDir.appendingPathComponent(key.filename)
        try? Data(repeating: 0xFF, count: 200).write(to: url)
        XCTAssertNil(cache.read(key: key))
    }

    func test_read_truncatedPayload_returnsNil() {
        let key = makeKey(buckets: 16)
        let peaks = makePeaks(count: 16)
        cache.write(peaks: peaks, key: key)
        // Re-write the file with the first 50 bytes only — header looks
        // valid but the payload is short. Decoder should treat as miss.
        let url = tempDir.appendingPathComponent(key.filename)
        let full = try! Data(contentsOf: url)
        try! full.prefix(50).write(to: url, options: .atomic)
        XCTAssertNil(cache.read(key: key))
    }

    func test_read_fieldDrift_returnsNil() {
        // Write a valid file, then re-encode it ourselves with a tweaked
        // header field (different durationSeconds). On disk the magic /
        // version pass but the stored field disagrees with what the
        // caller asks for; decoder should refuse it.
        let writeKey = makeKey(durationSeconds: 10)
        let peaks = makePeaks(count: 8)
        let drifted = cache.encode(peaks: peaks, key: makeKey(durationSeconds: 12))
        let url = tempDir.appendingPathComponent(writeKey.filename)
        try? drifted.write(to: url, options: .atomic)
        XCTAssertNil(cache.read(key: writeKey))
    }

    func test_disabledCache_isNoOp() {
        // `nil` directory disables both layers — read returns nil, write
        // silently does nothing (no temp file leaked anywhere).
        let disabled = WaveformDiskCache(directory: nil)
        disabled.write(peaks: makePeaks(), key: makeKey())
        XCTAssertNil(disabled.read(key: makeKey()))
    }

    func test_keyFilename_isStableAcrossCalls() {
        // The whole point of computing a deterministic filename is that
        // it survives across processes — i.e. it doesn't depend on
        // Swift's randomized hashValue. Pin it within one run as a
        // sanity check.
        let key = makeKey()
        XCTAssertEqual(key.filename, key.filename)
        XCTAssertFalse(key.filename.isEmpty)
        XCTAssertTrue(key.filename.hasSuffix(".wfcache"))
    }

    func test_keyFilename_changesWithBuckets() {
        let a = makeKey(buckets: 32)
        let b = makeKey(buckets: 64)
        XCTAssertNotEqual(a.filename, b.filename)
    }

    func test_keyFilename_changesWithMTime() {
        let a = makeKey(mtime: 1_700_000_000)
        let b = makeKey(mtime: 1_700_000_001)
        XCTAssertNotEqual(a.filename, b.filename)
    }

    func test_assetSignature_returnsNilForMissingFile() {
        let missing = URL(fileURLWithPath: "/tmp/definitely-not-a-real-file-\(UUID().uuidString)")
        XCTAssertNil(WaveformDiskCache.assetSignature(for: missing))
    }

    func test_assetSignature_returnsAttributesForRealFile() throws {
        let url = tempDir.appendingPathComponent("dummy.bin")
        let payload = Data(repeating: 0xAB, count: 128)
        try payload.write(to: url)
        let sig = WaveformDiskCache.assetSignature(for: url)
        XCTAssertNotNil(sig)
        XCTAssertEqual(sig?.size, 128)
        XCTAssertGreaterThan(sig?.mtime ?? 0, 0)
    }
}
