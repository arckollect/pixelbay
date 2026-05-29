#if canImport(AVFoundation)
import AVFoundation
import Foundation
import OSLog

private let log = Logger(subsystem: "com.pixelbay.PixelbayApp", category: "WaveformLoader")

// Reads PCM audio samples from an asset and reduces them to per-bucket
// peak pairs for waveform rendering. Two cache layers:
//
//   L1 — in-memory dict, keyed by (path, start, duration, buckets).
//        Hot path for the same project in the same session (seek /
//        scrub / zoom changes that re-render the same bucket count).
//
//   L2 — on-disk `WaveformDiskCache`, keyed by (path, mtime, size,
//        start, duration, buckets). Survives across launches so
//        reopening a project with hours of audio is a few KB of
//        FS reads instead of an AVAssetReader pass.
//
// Order: L1 → L2 → AVAssetReader; a hit at any layer populates the
// layers above it. The disk layer can be disabled by passing
// `cacheDirectory: nil` to the init (tests do this so the harness
// never touches ~/Library/Caches).
public actor WaveformLoader {
    public enum LoadError: Error, LocalizedError {
        case noAudioTrack(URL)
        case readerSetupFailed(String)
        case readingFailed(String)

        public var errorDescription: String? {
            switch self {
            case .noAudioTrack(let url): return "No audio track in \(url.lastPathComponent)"
            case .readerSetupFailed(let message): return "AVAssetReader setup: \(message)"
            case .readingFailed(let message): return "AVAssetReader read: \(message)"
            }
        }
    }

    private struct CacheKey: Hashable {
        let path: String
        let startSeconds: Double
        let durationSeconds: Double
        let buckets: Int
    }

    private var cache: [CacheKey: WaveformPeaks] = [:]
    private let diskCache: WaveformDiskCache

    public init() {
        self.init(cacheDirectory: WaveformDiskCache.defaultDirectory())
    }

    /// `cacheDirectory: nil` disables the disk layer entirely (only the
    /// in-memory L1 is used). Tests pass `nil` or a tempDir so the
    /// suite is hermetic.
    public init(cacheDirectory: URL?) {
        self.diskCache = WaveformDiskCache(directory: cacheDirectory)
    }

    /// Returns peaks for `url[start..start+duration]` aggregated into
    /// `buckets` buckets. L1 (in-memory) → L2 (disk) → AVAssetReader.
    public func peaks(
        forAssetAt url: URL,
        startSeconds: Double,
        durationSeconds: Double,
        buckets: Int
    ) async throws -> WaveformPeaks {
        let roundedStart = startSeconds.rounded(toPlaces: 3)
        let roundedDuration = durationSeconds.rounded(toPlaces: 3)
        let key = CacheKey(
            path: url.standardizedFileURL.path,
            startSeconds: roundedStart,
            durationSeconds: roundedDuration,
            buckets: buckets
        )
        if let hit = cache[key] { return hit }

        // L2: ask the disk cache for the same (asset signature, range,
        // buckets) tuple. `assetSignature` stat-s the file; if the
        // asset is missing we skip L2 and let AVAssetReader produce the
        // error.
        let diskKey = WaveformDiskCache.assetSignature(for: url).map { sig in
            WaveformDiskCache.Key(
                assetPath: key.path,
                assetMTime: sig.mtime,
                assetSize: sig.size,
                startSeconds: roundedStart,
                durationSeconds: roundedDuration,
                buckets: buckets
            )
        }
        if let diskKey, let hit = diskCache.read(key: diskKey) {
            cache[key] = hit
            return hit
        }

        let asset = AVURLAsset(url: url)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        guard let audioTrack = audioTracks.first else {
            throw LoadError.noAudioTrack(url)
        }

        let samples = try await readSamples(
            asset: asset,
            track: audioTrack,
            startSeconds: startSeconds,
            durationSeconds: durationSeconds
        )
        let peaks = WaveformPeaks.bucketize(samples: samples, buckets: buckets)
        cache[key] = peaks
        if let diskKey {
            diskCache.write(peaks: peaks, key: diskKey)
        }
        return peaks
    }

    private func readSamples(
        asset: AVURLAsset,
        track: AVAssetTrack,
        startSeconds: Double,
        durationSeconds: Double
    ) async throws -> [Float] {
        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: asset)
        } catch {
            throw LoadError.readerSetupFailed(error.localizedDescription)
        }
        // Force a single interleaved Float32 channel. Letting the reader
        // vend the source's native channel count was the silent-mic bug:
        // some mic captures (mono CAF whose ASBD reports a layout the
        // interleave de-mux below mis-strided) decoded to zero usable
        // samples and produced a blank waveform with reader.status
        // .completed — indistinguishable from "no audio". Requesting an
        // explicit mono channel layout makes AVAssetReader downmix to one
        // channel up front, so the parse is always a flat Float32 run
        // regardless of the source's channel geometry. System-audio
        // (stereo) happens to have survived the old path; mic (mono,
        // device-dependent layout) did not.
        var monoLayout = AudioChannelLayout()
        monoLayout.mChannelLayoutTag = kAudioChannelLayoutTag_Mono
        let layoutData = Data(bytes: &monoLayout, count: MemoryLayout<AudioChannelLayout>.size)
        let outputSettings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsNonInterleaved: false,
            AVNumberOfChannelsKey: 1,
            AVChannelLayoutKey: layoutData
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: outputSettings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else {
            throw LoadError.readerSetupFailed("can't add track output")
        }
        reader.add(output)

        // Trim the reader to [startSeconds, startSeconds + durationSeconds]
        // — saves time + memory on large source assets.
        let assetDuration = try await asset.load(.duration)
        let assetSeconds = CMTimeGetSeconds(assetDuration)
        let clampedStart = Swift.max(0, Swift.min(startSeconds, assetSeconds))
        let clampedDuration = Swift.max(0, Swift.min(durationSeconds, assetSeconds - clampedStart))
        if clampedDuration > 0 && (clampedStart > 0 || clampedDuration < assetSeconds) {
            let scale: CMTimeScale = 600
            let timeRange = CMTimeRange(
                start: CMTime(seconds: clampedStart, preferredTimescale: scale),
                duration: CMTime(seconds: clampedDuration, preferredTimescale: scale)
            )
            reader.timeRange = timeRange
        }

        guard reader.startReading() else {
            throw LoadError.readingFailed("startReading returned false: \(String(describing: reader.error))")
        }

        var samples: [Float] = []
        while let sampleBuffer = output.copyNextSampleBuffer() {
            guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { continue }
            let length = CMBlockBufferGetDataLength(blockBuffer)
            guard length > 0 else { continue }
            var data = Data(count: length)
            data.withUnsafeMutableBytes { (ptr: UnsafeMutableRawBufferPointer) in
                guard let baseAddress = ptr.baseAddress else { return }
                _ = CMBlockBufferCopyDataBytes(blockBuffer, atOffset: 0, dataLength: length, destination: baseAddress)
            }
            // Determine channel count from the format description.
            let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer)
            let asbd = formatDescription.flatMap { CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee }
            let channels = Int(asbd?.mChannelsPerFrame ?? 1)
            let floatCount = length / MemoryLayout<Float>.size
            let frameCount = channels > 0 ? floatCount / channels : floatCount
            data.withUnsafeBytes { (rawPtr: UnsafeRawBufferPointer) in
                guard let floats = rawPtr.bindMemory(to: Float.self).baseAddress else { return }
                samples.reserveCapacity(samples.count + frameCount)
                if channels <= 1 {
                    for i in 0..<frameCount {
                        samples.append(floats[i])
                    }
                } else {
                    // Interleaved L R L R … → averaged mono.
                    for frame in 0..<frameCount {
                        var acc: Float = 0
                        for c in 0..<channels {
                            acc += floats[frame * channels + c]
                        }
                        samples.append(acc / Float(channels))
                    }
                }
            }
        }
        if reader.status == .failed {
            throw LoadError.readingFailed(reader.error?.localizedDescription ?? "unknown")
        }
        // Diagnostic: a completed read that yielded zero samples is the
        // silent-mic signature. With the forced-mono output settings above
        // this should no longer happen, but log it loudly if it ever does
        // so a future content-specific regression isn't invisible again.
        if samples.isEmpty {
            log.error("waveform read produced 0 samples (status=\(reader.status.rawValue)) for \(asset.url.lastPathComponent, privacy: .public) — track waveform will be blank")
        }
        return samples
    }
}

private extension Double {
    func rounded(toPlaces places: Int) -> Double {
        let mult = pow(10.0, Double(places))
        return (self * mult).rounded() / mult
    }
}
#endif
