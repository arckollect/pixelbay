#if canImport(AVFoundation)
import AVFoundation
import CoreMedia
import Foundation
import OSLog
import PixelbayCapture
import PixelbayCore

private let log = Logger(subsystem: "com.pixelbay.PixelbayApp", category: "AssetWriterPipeline")

// AVAssetWriter-per-output-file sink for LiveCaptureBackend (HANDOFF §4.6).
//
//   • screen.mov     — H.264 video (single-track as of iter 10; was video +
//                      AAC sysaudio dual-track before but kept failing
//                      AVAssetWriter encoding while equivalent single-track
//                      writers worked — see HANDOFF §3.16 iter 10)
//   • sysaudio.caf   — AAC system audio (separate file as of iter 10)
//   • cam.mov        — H.264 video
//   • mic.caf        — AAC mic audio
//
// Conforms to PixelbayCapture.CaptureSink: append() is synchronous because
// SCStream and AVCaptureSession invoke their delegates on serial per-track
// queues and we want zero extra hops on the hot path. finish() is async
// because AVAssetWriter.finishWriting takes real time.
//
// Concurrency: append() is callable from up to four queues concurrently —
// SCStream's queue carries screenVideo + screenAudio serialised; the AV
// bridge has independent videoQueue (camVideo) and audioQueue (micAudio).
// All mutable state is guarded by a single NSLock.
//
// Crash safety: a `media/.recording-in-progress` marker file is created at
// construction and removed at finish() success. ProjectBundleStore's orphan
// scan looks for this on next launch (HANDOFF §4.6).
public final class AssetWriterPipeline: CaptureSink, @unchecked Sendable {

    public struct Configuration: Sendable {
        public var screenURL: URL
        public var camURL: URL?
        public var micURL: URL?
        public var sysAudioURL: URL?
        public var bundleURL: URL

        public init(
            screenURL: URL,
            camURL: URL?,
            micURL: URL?,
            sysAudioURL: URL?,
            bundleURL: URL
        ) {
            self.screenURL = screenURL
            self.camURL = camURL
            self.micURL = micURL
            self.sysAudioURL = sysAudioURL
            self.bundleURL = bundleURL
        }

        public init(plan: CapturePlan) {
            self.init(
                screenURL: plan.outputs.screenURL,
                camURL: plan.outputs.camURL,
                micURL: plan.outputs.micURL,
                sysAudioURL: plan.outputs.sysAudioURL,
                bundleURL: plan.bundleURL
            )
        }
    }

    public enum RecordingError: Error, Equatable, CustomStringConvertible, LocalizedError {
        case alreadyFinished
        case writerFailed(String)
        case cannotAddInput(String)
        case missingFormatDescription

        public var description: String {
            switch self {
            case .alreadyFinished: return "AssetWriterPipeline.finish() called twice"
            case .writerFailed(let m): return "AVAssetWriter failed: \(m)"
            case .cannotAddInput(let m): return "AVAssetWriter cannot add input: \(m)"
            case .missingFormatDescription: return "Sample buffer has no format description"
            }
        }

        // LocalizedError so log.error("...\(error.localizedDescription)...")
        // and SwiftUI Text(verbatim: error.localizedDescription) surface our
        // payload string instead of the generic "The operation couldn't be
        // completed (RecordingError error N.)" placeholder.
        public var errorDescription: String? { description }
    }

    public static let recordingMarkerFilename = ".recording-in-progress"

    private enum AudioEncoding {
        case aac    // screen.mov system audio
        case lpcm   // mic.caf
    }

    private final class WriterContext {
        let writer: AVAssetWriter
        var videoInput: AVAssetWriterInput?
        var audioInput: AVAssetWriterInput?
        let expectsVideo: Bool
        let expectsAudio: Bool
        let audioEncoding: AudioEncoding
        var ready = false
        // Set when this track's setup throws (e.g. AAC startWriting -11861).
        // Per-track scope, NOT global: a failing mic writer no longer drops
        // screen-video samples on the floor. The writer's `.failed` status
        // still surfaces via finalize() into CaptureSinkSummary.writerErrors.
        var setupFailed = false
        var firstPTS: CMTime?
        var lastPTS: CMTime?
        // Pre-startWriting buffers. Multi-input writers (screen.mov with
        // includeSystemAudio = true) cannot startWriting until BOTH the video
        // and audio inputs have been added (each derived lazily from its
        // first sample's format description). We buffer EVERY sample arriving
        // before that — overwriting the latest only would lose 100s of
        // milliseconds of video while waiting for the first audio packet.
        var bufferedVideo: [CMSampleBuffer] = []
        var bufferedAudio: [CMSampleBuffer] = []
        var videoStats = TrackStats()
        var audioStats = TrackStats()

        init(
            writer: AVAssetWriter,
            expectsVideo: Bool,
            expectsAudio: Bool,
            audioEncoding: AudioEncoding
        ) {
            self.writer = writer
            self.expectsVideo = expectsVideo
            self.expectsAudio = expectsAudio
            self.audioEncoding = audioEncoding
        }
    }

    private let lock = NSLock()
    private let config: Configuration
    private let markerURL: URL
    private var screenContext: WriterContext?
    private var camContext: WriterContext?
    private var micContext: WriterContext?
    private var sysAudioContext: WriterContext?
    private var finished = false

    public init(configuration: Configuration) throws {
        self.config = configuration
        let media = configuration.bundleURL.appendingPathComponent("media")
        try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
        let marker = media.appendingPathComponent(Self.recordingMarkerFilename)
        FileManager.default.createFile(atPath: marker.path, contents: nil, attributes: nil)
        self.markerURL = marker
        log.info("init bundle=\(configuration.bundleURL.lastPathComponent, privacy: .public) screen=\(configuration.screenURL.lastPathComponent, privacy: .public) cam=\(configuration.camURL?.lastPathComponent ?? "nil", privacy: .public) mic=\(configuration.micURL?.lastPathComponent ?? "nil", privacy: .public) sysaudio=\(configuration.sysAudioURL?.lastPathComponent ?? "nil", privacy: .public)")
    }

    public convenience init(plan: CapturePlan) throws {
        try self.init(configuration: Configuration(plan: plan))
    }

    public func append(_ sampleBuffer: CMSampleBuffer, on track: CaptureTrack) {
        lock.lock()
        defer { lock.unlock() }
        if finished { return }
        // Per-track failure isolation: if this track's writer already failed
        // setup (e.g. AAC startWriting -11861), drop its samples but keep
        // every other track recording. The earlier global `deferredError`
        // cascade meant a misconfigured mic writer would silently drop every
        // subsequent screen.mov frame — the editor then opened a 0.5s recording
        // even though the user recorded 30s.
        if isTrackFailed(track) { return }
        do {
            switch track {
            case .screenVideo:
                // Screen video is single-track-video as of iter 10 — handled
                // identically to cam.mov (which works flawlessly). Was a
                // dual-track .mov containing video + sysaudio before but
                // AVAssetWriter kept failing the dual-track encoding ~1s in.
                let firstSample = (screenContext == nil)
                try handleSingleVideo(context: &screenContext, url: config.screenURL, fileType: .mov, sampleBuffer: sampleBuffer)
                if firstSample { log.info("first screen video sample arrived") }
            case .screenAudio:
                guard let url = config.sysAudioURL else { return }
                let firstSample = (sysAudioContext == nil)
                // Sysaudio encodes to AAC into its own .caf — same shape as
                // mic.caf which works perfectly with the iter-9 settings.
                try handleSingleAudio(context: &sysAudioContext, url: url, fileType: .caf, sampleBuffer: sampleBuffer, encoding: .aac)
                if firstSample { log.info("first sysaudio sample arrived") }
            case .camVideo:
                guard let url = config.camURL else { return }
                let firstSample = (camContext == nil)
                try handleSingleVideo(context: &camContext, url: url, fileType: .mov, sampleBuffer: sampleBuffer)
                if firstSample { log.info("first cam sample arrived") }
            case .micAudio:
                guard let url = config.micURL else { return }
                let firstSample = (micContext == nil)
                // Mic encodes to AAC, not LPCM. Two earlier attempts failed:
                // 1. Explicit Int16 LPCM made AVAssetWriterInput.append return
                //    false sample-after-sample (mic.caf came out at 0.04s).
                // 2. Passthrough (outputSettings: nil) made startWriting fail
                //    outright — AVAssetWriter rejects Float32 non-interleaved
                //    LPCM (the AVCaptureAudioDataOutput default) into a .caf
                //    container without explicit reformatting.
                // AAC into .caf is what sysaudio also uses. Voice quality is
                // fine and the file size is bounded.
                try handleSingleAudio(context: &micContext, url: url, fileType: .caf, sampleBuffer: sampleBuffer, encoding: .aac)
                if firstSample { log.info("first mic sample arrived") }
            }
        } catch {
            log.error("append threw on \(String(describing: track), privacy: .public): \(error.localizedDescription, privacy: .public)")
            markTrackFailed(track)
        }
    }

    private func isTrackFailed(_ track: CaptureTrack) -> Bool {
        switch track {
        case .screenVideo: return screenContext?.setupFailed == true
        case .screenAudio: return sysAudioContext?.setupFailed == true
        case .camVideo:    return camContext?.setupFailed == true
        case .micAudio:    return micContext?.setupFailed == true
        }
    }

    private func markTrackFailed(_ track: CaptureTrack) {
        switch track {
        case .screenVideo: screenContext?.setupFailed = true
        case .screenAudio: sysAudioContext?.setupFailed = true
        case .camVideo:    camContext?.setupFailed = true
        case .micAudio:    micContext?.setupFailed = true
        }
    }

    public func finish() async throws -> CaptureSinkSummary {
        let snapshot = try claimForFinish()

        let screenResult = await finalize(snapshot.screen)
        let camResult = await finalize(snapshot.cam)
        let micResult = await finalize(snapshot.mic)
        let sysAudioResult = await finalize(snapshot.sysAudio)

        try? FileManager.default.removeItem(at: markerURL)

        var stats: [CaptureTrack: TrackStats] = [:]
        if let s = screenResult.videoStats { stats[.screenVideo] = s }
        if let s = sysAudioResult.audioStats { stats[.screenAudio] = s }
        if let s = camResult.videoStats { stats[.camVideo] = s }
        if let s = micResult.audioStats { stats[.micAudio] = s }

        // Collect writer / append errors as Strings on the summary instead
        // of throwing — earlier behaviour threw on the first writer error,
        // which made LiveCaptureBackend.stop()'s catch fall back to .empty
        // and lose the trackStats dictionary. The smoke UI then showed
        // "NO SAMPLES REACHED THE SINK" even when the Console log proved
        // dozens of samples succeeded. Caller is responsible for treating
        // a non-empty writerErrors as a failed recording.
        var writerErrors: [String] = []
        for result in [screenResult, camResult, micResult, sysAudioResult] {
            if let err = result.writerError {
                writerErrors.append(Self.describe(err))
            }
        }

        return CaptureSinkSummary(
            screenDuration: screenResult.duration,
            camDuration: camResult.duration,
            micDuration: micResult.duration,
            sysAudioDuration: sysAudioResult.duration,
            trackStats: stats,
            writerErrors: writerErrors
        )
    }

    private static func describe(_ error: Error) -> String {
        if let recordingError = error as? RecordingError {
            return recordingError.description
        }
        let nsError = error as NSError
        return "\(nsError.domain) code=\(nsError.code) — \(nsError.localizedDescription)"
    }

    // Synchronous critical section. Pulled out of finish() so the rest of
    // finish() can be async without NSLock crossing a suspension point —
    // Swift 6 forbids that.
    private func claimForFinish() throws -> FinishSnapshot {
        lock.lock()
        defer { lock.unlock() }
        if finished {
            throw RecordingError.alreadyFinished
        }
        finished = true
        return FinishSnapshot(
            screen: screenContext,
            cam: camContext,
            mic: micContext,
            sysAudio: sysAudioContext
        )
    }

    private struct FinishSnapshot {
        let screen: WriterContext?
        let cam: WriterContext?
        let mic: WriterContext?
        let sysAudio: WriterContext?
    }

    // MARK: - Per-track entry points

    /// Lower bound (seconds) below which a video track's first PTS is treated
    /// as a pre-clock-lock sample rather than a real host-clock timestamp.
    /// Host-clock PTS is seconds-since-boot — always far larger than this — so
    /// 1 s is an enormous safety margin over the observed pre-lock values
    /// (0 s and 0.033 s) while never excluding a genuine recording start.
    private static let minPlausibleHostClockPTSSeconds: Double = 1.0

    private func handleSingleVideo(
        context: inout WriterContext?,
        url: URL,
        fileType: AVFileType,
        sampleBuffer: CMSampleBuffer
    ) throws {
        // AVCaptureVideoDataOutput's first sample(s) after startRunning can
        // arrive before the session sync clock has locked into the host-clock
        // domain. SCStream screen samples are host-clock from the very first
        // frame, but the cam emits one or more pre-lock frames whose PTS is in
        // a session-relative ~0-based domain — observed as pts=0 (cold start)
        // AND pts=0.033 s (warm restart between scenes). Real host-clock PTS is
        // seconds-since-boot, always far larger than any plausible recording (a
        // running Mac's uptime is minutes-to-days). Starting the writer at such
        // a tiny startPTS and then appending real host-clock samples produces a
        // .mov whose duration metadata is the host-clock value of the LAST
        // sample (≈ 742,900 s / 8.6 days when the machine has been up that
        // long); that corrupt asset duration flows into the merged project and
        // destabilises the editor when the clip lands on the timeline. Drop any
        // leading video sample whose PTS is implausibly small to be a host
        // clock time, so the writer latches onto the first real clock-locked
        // sample — single-frame loss, no user-visible artifact. The screen path
        // also runs through here but its first PTS is always large, so it's
        // unaffected. HANDOFF §3.16 iter #14 (broadened from the original
        // `pts == 0` test after a between-scenes recording produced a 0.033 s
        // pre-lock frame that slipped through and corrupted cam-*.mov).
        if context == nil {
            let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            if pts.seconds < Self.minPlausibleHostClockPTSSeconds {
                log.notice("dropping suspect pre-lock first video sample for \(url.lastPathComponent, privacy: .public): pts=\(pts.value)/\(pts.timescale) seconds=\(pts.seconds) flags=\(pts.flags.rawValue)")
                return
            }
        }
        if context == nil {
            let writer = try AVAssetWriter(url: url, fileType: fileType)
            context = WriterContext(
                writer: writer,
                expectsVideo: true,
                expectsAudio: false,
                audioEncoding: .aac
            )
        }
        guard let ctx = context else { return }
        try addInputIfNeeded(to: ctx, sample: sampleBuffer, isVideo: true)
        try advance(ctx, currentSample: sampleBuffer, currentIsVideo: true)
    }

    private func handleSingleAudio(
        context: inout WriterContext?,
        url: URL,
        fileType: AVFileType,
        sampleBuffer: CMSampleBuffer,
        encoding: AudioEncoding
    ) throws {
        if context == nil {
            let writer = try AVAssetWriter(url: url, fileType: fileType)
            context = WriterContext(
                writer: writer,
                expectsVideo: false,
                expectsAudio: true,
                audioEncoding: encoding
            )
        }
        guard let ctx = context else { return }
        try addInputIfNeeded(to: ctx, sample: sampleBuffer, isVideo: false)
        try advance(ctx, currentSample: sampleBuffer, currentIsVideo: false)
    }

    // MARK: - Lazy input + writer state

    private func addInputIfNeeded(
        to ctx: WriterContext,
        sample: CMSampleBuffer,
        isVideo: Bool
    ) throws {
        if isVideo {
            guard ctx.videoInput == nil else { return }
            let input = try makeVideoInput(from: sample)
            guard ctx.writer.canAdd(input) else {
                throw RecordingError.cannotAddInput("video into \(ctx.writer.outputURL.lastPathComponent)")
            }
            ctx.writer.add(input)
            ctx.videoInput = input
        } else {
            guard ctx.audioInput == nil else { return }
            let input = try makeAudioInput(from: sample, encoding: ctx.audioEncoding)
            guard ctx.writer.canAdd(input) else {
                throw RecordingError.cannotAddInput("audio into \(ctx.writer.outputURL.lastPathComponent)")
            }
            ctx.writer.add(input)
            ctx.audioInput = input
        }
    }

    private func advance(
        _ ctx: WriterContext,
        currentSample sb: CMSampleBuffer,
        currentIsVideo: Bool
    ) throws {
        let allInputsReady = (!ctx.expectsVideo || ctx.videoInput != nil)
            && (!ctx.expectsAudio || ctx.audioInput != nil)

        if !ctx.ready {
            guard allInputsReady else {
                // Still waiting for the other expected track's first sample
                // before AVAssetWriter.startWriting(). Buffer EVERY sample —
                // an earlier version kept only the latest, which dropped 100s
                // of milliseconds of video while waiting for the first
                // system-audio packet (≈ 1s of lost video in real captures).
                if currentIsVideo {
                    ctx.bufferedVideo.append(sb)
                } else {
                    ctx.bufferedAudio.append(sb)
                }
                return
            }

            // All inputs added — start the writer using the earliest PTS we
            // have across all buffered + current samples.
            let bufferedVideoPTS = ctx.bufferedVideo.first.map(CMSampleBufferGetPresentationTimeStamp)
            let bufferedAudioPTS = ctx.bufferedAudio.first.map(CMSampleBufferGetPresentationTimeStamp)
            let candidates: [CMTime] = [
                bufferedVideoPTS,
                bufferedAudioPTS,
                CMSampleBufferGetPresentationTimeStamp(sb)
            ].compactMap { $0 }
            let startPTS = candidates.min(by: { CMTimeCompare($0, $1) < 0 }) ?? .zero

            guard ctx.writer.startWriting() else {
                let underlying = ctx.writer.error
                let nsError = underlying as NSError?
                let detail = "\(ctx.writer.outputURL.lastPathComponent) status=\(ctx.writer.status.rawValue) underlying=\(nsError?.localizedDescription ?? "nil") domain=\(nsError?.domain ?? "?") code=\(nsError?.code ?? -1)"
                log.error("startWriting failed: \(detail, privacy: .public)")
                throw RecordingError.writerFailed(detail)
            }
            ctx.writer.startSession(atSourceTime: startPTS)
            ctx.ready = true
            ctx.firstPTS = startPTS
            log.info("started writer \(ctx.writer.outputURL.lastPathComponent, privacy: .public) at PTS \(startPTS.value)/\(startPTS.timescale) bufferedVideo=\(ctx.bufferedVideo.count) bufferedAudio=\(ctx.bufferedAudio.count)")

            if let input = ctx.videoInput {
                for buf in ctx.bufferedVideo {
                    tryAppend(input, buf, into: ctx, isVideo: true, fromBuffer: true)
                }
            }
            ctx.bufferedVideo.removeAll(keepingCapacity: false)
            if let input = ctx.audioInput {
                for buf in ctx.bufferedAudio {
                    tryAppend(input, buf, into: ctx, isVideo: false, fromBuffer: true)
                }
            }
            ctx.bufferedAudio.removeAll(keepingCapacity: false)

            // Append the sample that just triggered readiness (not buffered —
            // we reached this branch without taking the early-out above).
            let input = currentIsVideo ? ctx.videoInput : ctx.audioInput
            if let input = input { tryAppend(input, sb, into: ctx, isVideo: currentIsVideo, fromBuffer: false) }
        } else {
            let input = currentIsVideo ? ctx.videoInput : ctx.audioInput
            if let input = input { tryAppend(input, sb, into: ctx, isVideo: currentIsVideo, fromBuffer: false) }
        }
    }

    private func tryAppend(
        _ input: AVAssetWriterInput,
        _ sb: CMSampleBuffer,
        into ctx: WriterContext,
        isVideo: Bool,
        fromBuffer: Bool
    ) {
        // expectsMediaDataInRealTime = true means AVAssetWriter pulls fast
        // enough that isReadyForMoreMediaData rarely returns false. When it
        // does, the right call is to drop rather than block the bridge queue.
        guard input.isReadyForMoreMediaData else {
            if isVideo { ctx.videoStats.droppedNotReadyCount += 1 }
            else { ctx.audioStats.droppedNotReadyCount += 1 }
            return
        }
        if input.append(sb) {
            ctx.lastPTS = CMSampleBufferGetPresentationTimeStamp(sb)
            if isVideo {
                ctx.videoStats.appendedCount += 1
                if fromBuffer { ctx.videoStats.bufferedThenAppendedCount += 1 }
            } else {
                ctx.audioStats.appendedCount += 1
                if fromBuffer { ctx.audioStats.bufferedThenAppendedCount += 1 }
            }
        } else {
            // input.append returned false. The writer is now in .failed (or
            // about to be) and writer.error has the underlying NSError. We
            // surface this in finalize() via writer.error, but also count it
            // here so per-track stats reflect what happened sample-by-sample.
            // Log the first failure per (track) so we can correlate which
            // sample broke it.
            let firstFailure = isVideo ? ctx.videoStats.appendFailedCount == 0 : ctx.audioStats.appendFailedCount == 0
            if firstFailure {
                let nsError = ctx.writer.error as NSError?
                let pts = CMSampleBufferGetPresentationTimeStamp(sb)
                log.error("append returned false on \(ctx.writer.outputURL.lastPathComponent, privacy: .public) (\(isVideo ? "video" : "audio", privacy: .public)) at PTS \(pts.value)/\(pts.timescale): domain=\(nsError?.domain ?? "?") code=\(nsError?.code ?? -1) desc=\(nsError?.localizedDescription ?? "nil") reason=\(nsError?.localizedFailureReason ?? "nil")")
            }
            if isVideo { ctx.videoStats.appendFailedCount += 1 }
            else { ctx.audioStats.appendFailedCount += 1 }
        }
    }

    // MARK: - Input construction

    private func makeVideoInput(from sb: CMSampleBuffer) throws -> AVAssetWriterInput {
        guard let format = CMSampleBufferGetFormatDescription(sb) else {
            throw RecordingError.missingFormatDescription
        }
        let dims = CMVideoFormatDescriptionGetDimensions(format)
        // Bitrate: screen recordings need more bits than camera footage
        // because text and UI edges show compression immediately. Use a
        // higher bpp/frame ladder and a larger cap now that capture can keep
        // UHD frames. This yields ≈22 Mbps at 1080p60, ≈40 Mbps at 1440p60,
        // and ≈90 Mbps at 4K60, while still staying below the runaway rates
        // that caused the early encoder failures.
        let pixelCount = Int(dims.width) * Int(dims.height)
        let bitrate = min(Int(Double(pixelCount) * 60 * 0.18), 120_000_000)
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(dims.width),
            AVVideoHeightKey: Int(dims.height),
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitrate,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                // Keyframe every 2s at 60fps. 60-frame intervals at high
                // bitrate force a huge I-frame every second — too much
                // pressure on the encoder.
                AVVideoMaxKeyFrameIntervalKey: 120
                // Deliberately NO AVVideoExpectedSourceFrameRateKey — it's a
                // hint, not a contract, and SCStream's actual delivery rate
                // is variable; mismatch was implicated in iteration 7's
                // immediate-failure regression.
            ]
        ]
        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: settings,
            sourceFormatHint: format
        )
        input.expectsMediaDataInRealTime = true
        return input
    }

    private func makeAudioInput(
        from sb: CMSampleBuffer,
        encoding: AudioEncoding
    ) throws -> AVAssetWriterInput {
        guard let format = CMSampleBufferGetFormatDescription(sb) else {
            throw RecordingError.missingFormatDescription
        }
        let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee
        let channels = Int(asbd?.mChannelsPerFrame ?? 2)
        let sampleRate = asbd?.mSampleRate ?? 44_100

        let input: AVAssetWriterInput
        switch encoding {
        case .aac:
            // Normalise to an AAC-LC-supported configuration. The encoder
            // returns -11861 (AVErrorEncoderDecoderConfigurationNotAvailable)
            // when the requested config is unrealizable — three cases hit:
            //   1. Channels > 2 with no AVChannelLayoutKey. Aggregate /
            //      multichannel USB interfaces happily deliver 4-6 ch.
            //   2. Sample rate not in the AAC-LC supported set
            //      {8000,11025,12000,16000,22050,24000,32000,44100,48000}.
            //      96kHz pro-audio mics + some screen-capture sysaudio
            //      paths land here.
            //   3. Bitrate too high for the rate/channels combo. AAC-LC's
            //      valid bitrate ceiling scales with the sample rate, so a
            //      fixed 64k/128k that's fine at 44.1/48kHz is REJECTED at the
            //      low rates a Bluetooth HFP mic delivers (AirPods / headsets
            //      hand us 8 or 16 kHz mono). That rejection is the -11861
            //      "encoding parameters are not supported" the whole mic track
            //      died on. Fix: only pin an explicit bitrate at normal rates
            //      (≥32 kHz, where 64/128k is always valid); below that, omit
            //      the key and let the encoder choose a rate-appropriate
            //      default — never unrealizable.
            // The encoder will resample/downmix internally — we just need
            // to ask for a valid output config. Source quality is bounded
            // by the input buffers regardless.
            let outChannels = min(max(channels, 1), 2)
            let supportedRates: [Double] = [8000, 11025, 12000, 16000, 22050, 24000, 32000, 44100, 48000]
            let outRate = supportedRates.min(by: { abs($0 - sampleRate) < abs($1 - sampleRate) }) ?? 48_000
            var settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVNumberOfChannelsKey: outChannels,
                AVSampleRateKey: outRate
            ]
            if outRate >= 32_000 {
                settings[AVEncoderBitRateKey] = outChannels == 1 ? 64_000 : 128_000
            }
            if outChannels == 2 {
                var layout = AudioChannelLayout()
                layout.mChannelLayoutTag = kAudioChannelLayoutTag_Stereo
                settings[AVChannelLayoutKey] = Data(
                    bytes: &layout,
                    count: MemoryLayout<AudioChannelLayout>.size
                )
            }
            log.info("AAC writer settings: in ch=\(channels) rate=\(sampleRate) → out ch=\(outChannels) rate=\(outRate)")
            input = AVAssetWriterInput(
                mediaType: .audio,
                outputSettings: settings,
                sourceFormatHint: format
            )
        case .lpcm:
            // Passthrough write of the source ASBD into a .caf container.
            // Currently unused — both attempts to use this for the live mic
            // (Float32 non-interleaved from AVCaptureAudioDataOutput) failed:
            // explicit Int16 settings made append silently reject every
            // sample, and outputSettings: nil made startWriting fail
            // outright. The mic now encodes to AAC (the same path system
            // audio uses). Kept for completeness: a future caller writing
            // already-LPCM-formatted samples (e.g. an imported .wav) can
            // still use this branch.
            input = AVAssetWriterInput(
                mediaType: .audio,
                outputSettings: nil,
                sourceFormatHint: format
            )
        }
        input.expectsMediaDataInRealTime = true
        return input
    }

    // MARK: - Finalisation

    private struct FinalizeResult {
        var duration: RationalTime?
        var videoStats: TrackStats?
        var audioStats: TrackStats?
        var writerError: Error?
    }

    private func finalize(_ ctx: WriterContext?) async -> FinalizeResult {
        guard let ctx = ctx else { return FinalizeResult() }
        let videoStats = ctx.expectsVideo ? ctx.videoStats : nil
        let audioStats = ctx.expectsAudio ? ctx.audioStats : nil
        // markAsFinished is only legal AFTER startWriting() — if the writer
        // never started (e.g. screen.mov expected audio that never arrived)
        // calling it raises NSInternalInconsistencyException. Cancel cleanly
        // instead; cancelWriting also guarantees no half-written file is
        // left behind.
        guard ctx.ready else {
            // The writer can reach `.failed` during setup — e.g. an AAC
            // `startWriting()` rejecting an unsupported mic format with
            // -11861 — without ever becoming ready. `append(_:on:)` catches
            // that throw and marks the track failed, but if we return no
            // `writerError` here the failure is invisible to the caller:
            // `writerErrors` stays empty, the recording is treated as fully
            // successful, and a 0-byte mic asset gets persisted and then
            // spams the editor with "media damaged" on every waveform load.
            // Surface it so PostCaptureView can warn (the screen/cam tracks
            // still survive — per-track isolation is unchanged). A writer
            // that simply never started (status `.unknown`, e.g. a screen
            // writer whose expected audio never arrived) is NOT an error.
            var setupError: Error?
            if ctx.writer.status == .failed {
                let nsError = ctx.writer.error as NSError?
                let detail = "domain=\(nsError?.domain ?? "?") code=\(nsError?.code ?? -1) desc=\(nsError?.localizedDescription ?? "nil") reason=\(nsError?.localizedFailureReason ?? "nil")"
                setupError = RecordingError.writerFailed(
                    "\(ctx.writer.outputURL.lastPathComponent): \(detail)"
                )
                log.error("writer \(ctx.writer.outputURL.lastPathComponent, privacy: .public) FAILED before ready: \(detail, privacy: .public)")
            }
            ctx.writer.cancelWriting()
            return FinalizeResult(videoStats: videoStats, audioStats: audioStats, writerError: setupError)
        }
        ctx.videoInput?.markAsFinished()
        ctx.audioInput?.markAsFinished()
        let writer = ctx.writer
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            writer.finishWriting { cont.resume() }
        }
        // finishWriting can land in .failed (or even .cancelled) without ever
        // throwing — the previous code silently produced a malformed .mov in
        // that case. Surface writer.error so finish() can rethrow.
        var writerError: Error?
        if writer.status == .failed {
            let nsError = writer.error as NSError?
            let detail = "domain=\(nsError?.domain ?? "?") code=\(nsError?.code ?? -1) desc=\(nsError?.localizedDescription ?? "nil") reason=\(nsError?.localizedFailureReason ?? "nil") userInfo=\(nsError?.userInfo.description ?? "nil")"
            writerError = RecordingError.writerFailed(
                "\(writer.outputURL.lastPathComponent): \(detail)"
            )
            log.error("writer \(writer.outputURL.lastPathComponent, privacy: .public) FAILED: \(detail, privacy: .public) videoStats=\(String(describing: ctx.videoStats), privacy: .public) audioStats=\(String(describing: ctx.audioStats), privacy: .public)")
        } else {
            log.info("writer \(writer.outputURL.lastPathComponent, privacy: .public) finished status=\(writer.status.rawValue) videoStats=\(String(describing: ctx.videoStats), privacy: .public) audioStats=\(String(describing: ctx.audioStats), privacy: .public)")
        }
        let duration: RationalTime?
        if let first = ctx.firstPTS, let last = ctx.lastPTS {
            // CMTimeSubtract can promote to a large common timescale when
            // the two operands have different ones — when we then forward
            // the raw value/timescale to RationalTime, the resulting
            // .seconds reading came out wildly wrong (cam.mov reported
            // 36 hours for a 47s recording in iteration 8). Anchor on
            // CMTimeGetSeconds which always returns Float64 seconds.
            //
            // Iteration 12: even after iter-9's CMTimeGetSeconds anchor,
            // cam.mov has been observed reporting ~37 hours for a 23s
            // recording. The likeliest cause is a CMTime epoch mismatch
            // between first and last where CMTimeSubtract produces a
            // CMTime in a strange domain whose CMTimeGetSeconds reading
            // is not the wall-clock delta. Defence: also compute the
            // delta as `lastSec − firstSec` from each operand
            // independently; if it disagrees with the subtract-then-
            // convert path by more than 0.5s, prefer the per-operand
            // path (which is robust to any per-CMTime weirdness, but
            // will still be wrong if first/last live in different
            // epochs — that's the next iteration's problem).
            let dur = CMTimeSubtract(last, first)
            let durSecSubtract = CMTimeGetSeconds(dur)
            let durSecPerOperand = CMTimeGetSeconds(last) - CMTimeGetSeconds(first)
            let chosen: Double
            if abs(durSecSubtract - durSecPerOperand) > 0.5 {
                chosen = durSecPerOperand
            } else {
                chosen = durSecSubtract
            }
            duration = (chosen.isFinite && chosen >= 0) ? .seconds(chosen) : nil
            log.notice("duration calc \(writer.outputURL.lastPathComponent, privacy: .public): firstPTS=\(first.value)/\(first.timescale)(epoch=\(first.epoch),flags=\(first.flags.rawValue)) lastPTS=\(last.value)/\(last.timescale)(epoch=\(last.epoch),flags=\(last.flags.rawValue)) dur=\(dur.value)/\(dur.timescale)(epoch=\(dur.epoch),flags=\(dur.flags.rawValue)) durSecSubtract=\(durSecSubtract) durSecPerOperand=\(durSecPerOperand) chosen=\(chosen)")
        } else {
            duration = nil
            log.notice("duration calc \(writer.outputURL.lastPathComponent, privacy: .public): firstPTS=\(ctx.firstPTS != nil ? "set" : "nil") lastPTS=\(ctx.lastPTS != nil ? "set" : "nil")")
        }
        return FinalizeResult(
            duration: duration,
            videoStats: videoStats,
            audioStats: audioStats,
            writerError: writerError
        )
    }
}

#endif
