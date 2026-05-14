@testable import PixelbayTimelineUI
import XCTest

/// Pin the bucketize math. The live AVAssetReader path isn't tested
/// here (it requires a real audio file + the runtime); the
/// `WaveformLoader` exercises this same `bucketize(...)` to reduce
/// extracted samples into peak pairs.
final class WaveformPeaksTests: XCTestCase {
    func test_bucketize_emptySamples_returnsEmpty() {
        let peaks = WaveformPeaks.bucketize(samples: [], buckets: 10)
        XCTAssertEqual(peaks, .empty)
    }

    func test_bucketize_zeroBuckets_returnsEmpty() {
        let peaks = WaveformPeaks.bucketize(samples: [0.1, 0.2, 0.3], buckets: 0)
        XCTAssertEqual(peaks, .empty)
    }

    func test_bucketize_singleBucket_yieldsGlobalMinMax() {
        let samples: [Float] = [-0.4, 0.1, 0.7, -0.2, 0.5]
        let peaks = WaveformPeaks.bucketize(samples: samples, buckets: 1)
        XCTAssertEqual(peaks.bucketCount, 1)
        XCTAssertEqual(peaks.min, [-0.4])
        XCTAssertEqual(peaks.max, [0.7])
    }

    func test_bucketize_evenSplit_acrossTwoBuckets() {
        // 4 samples / 2 buckets = 2 samples each.
        let samples: [Float] = [-0.3, 0.5, 0.2, -0.8]
        let peaks = WaveformPeaks.bucketize(samples: samples, buckets: 2)
        XCTAssertEqual(peaks.bucketCount, 2)
        XCTAssertEqual(peaks.min, [-0.3, -0.8])
        XCTAssertEqual(peaks.max, [0.5, 0.2])
    }

    func test_bucketize_unevenSplit_distributesSamples() {
        // 5 samples / 2 buckets — first bucket gets samples 0..<2,
        // second gets 2..<5 (floating-point boundary at 2.5 → first
        // bucket end = 2, second bucket = 5).
        let samples: [Float] = [0.1, 0.4, -0.2, 0.7, 0.3]
        let peaks = WaveformPeaks.bucketize(samples: samples, buckets: 2)
        XCTAssertEqual(peaks.bucketCount, 2)
        XCTAssertEqual(peaks.min[0], 0.1)
        XCTAssertEqual(peaks.max[0], 0.4)
        XCTAssertEqual(peaks.min[1], -0.2)
        XCTAssertEqual(peaks.max[1], 0.7)
    }

    func test_bucketize_morBucketsThanSamples_capsAtSampleCount() {
        let samples: [Float] = [0.5, -0.5]
        let peaks = WaveformPeaks.bucketize(samples: samples, buckets: 100)
        // Caps to samples.count = 2.
        XCTAssertEqual(peaks.bucketCount, 2)
    }

    func test_bucketize_silence_yieldsZeroPeaks() {
        let samples = Array<Float>(repeating: 0, count: 1000)
        let peaks = WaveformPeaks.bucketize(samples: samples, buckets: 10)
        XCTAssertEqual(peaks.bucketCount, 10)
        XCTAssertEqual(peaks.min.allSatisfy { $0 == 0 }, true)
        XCTAssertEqual(peaks.max.allSatisfy { $0 == 0 }, true)
    }

    func test_bucketize_alternatingPolarity_capturesBothExtremes() {
        // Samples alternating between +0.9 and -0.9 — every bucket should
        // see both.
        let samples = (0..<200).map { Float($0 % 2 == 0 ? 0.9 : -0.9) }
        let peaks = WaveformPeaks.bucketize(samples: samples, buckets: 20)
        XCTAssertEqual(peaks.bucketCount, 20)
        XCTAssertEqual(peaks.min.allSatisfy { $0 == -0.9 }, true)
        XCTAssertEqual(peaks.max.allSatisfy { $0 == 0.9 }, true)
    }

    func test_waveformPeaks_emptyHasZeroBucketCount() {
        XCTAssertEqual(WaveformPeaks.empty.bucketCount, 0)
    }
}
