import Foundation

// Per-bucket min/max peak values for a slice of audio samples. Used by
// WaveformLayer to draw a vertical bar per bucket spanning [min, max].
//
// `min` and `max` are normalised to [-1, 1]; the layer scales them to
// the lane height at draw time. Both arrays are the same length —
// `buckets`.
public struct WaveformPeaks: Sendable, Equatable {
    public var min: [Float]
    public var max: [Float]
    public var bucketCount: Int { Swift.min(min.count, max.count) }

    public init(min: [Float], max: [Float]) {
        precondition(min.count == max.count, "WaveformPeaks min/max counts diverged")
        self.min = min
        self.max = max
    }

    public static let empty = WaveformPeaks(min: [], max: [])

    /// Reduces a flat sample buffer into per-bucket min/max peak pairs.
    ///
    /// Intended use is one bucket per visual pixel; the live audio loader
    /// extracts raw float samples from AVAssetReader, then calls this to
    /// shrink them to the timeline's display resolution. Pure-data so the
    /// bucketing math is unit-testable without touching AVFoundation.
    ///
    /// Edge cases:
    ///   • `samples.isEmpty` → `.empty` regardless of `buckets`.
    ///   • `buckets <= 0` → `.empty`.
    ///   • `buckets > samples.count` → returns `samples.count` buckets
    ///     (one sample per bucket, no padding). The caller can decide
    ///     whether to pad zeros at render time.
    public static func bucketize(samples: [Float], buckets: Int) -> WaveformPeaks {
        guard !samples.isEmpty, buckets > 0 else { return .empty }
        let actualBuckets = Swift.min(buckets, samples.count)
        // Use floating-point bucket boundaries so we don't lose samples to
        // integer-truncation drift over large counts. Each bucket spans
        // `[start, end)` where end = (i+1) * samples.count / buckets.
        var minBuckets: [Float] = []
        var maxBuckets: [Float] = []
        minBuckets.reserveCapacity(actualBuckets)
        maxBuckets.reserveCapacity(actualBuckets)
        let step = Double(samples.count) / Double(actualBuckets)
        for i in 0..<actualBuckets {
            let start = Int((Double(i) * step).rounded(.down))
            let end = Int((Double(i + 1) * step).rounded(.down))
            let range = start..<Swift.min(end, samples.count)
            guard !range.isEmpty else { continue }
            var bucketMin: Float = .greatestFiniteMagnitude
            var bucketMax: Float = -.greatestFiniteMagnitude
            for j in range {
                let s = samples[j]
                if s < bucketMin { bucketMin = s }
                if s > bucketMax { bucketMax = s }
            }
            minBuckets.append(bucketMin)
            maxBuckets.append(bucketMax)
        }
        return WaveformPeaks(min: minBuckets, max: maxBuckets)
    }
}
