#if canImport(ScreenCaptureKit) && canImport(AVFoundation)
import AVFoundation
import CoreMedia
import Foundation
import OSLog
import PixelbayCore
import ScreenCaptureKit

private let log = Logger(subsystem: "com.pixelbay.PixelbayApp", category: "LiveCaptureBackend")

// Live wiring for ScreenCaptureKit + AVCaptureSession behind the
// CaptureBackend protocol. State-machine logic is exercised against
// FakeCaptureBackend in CaptureSessionTests; this type is exercised via the
// §4.5b manual smoke test (record into a real .pixelbay bundle, verify three
// files exist) plus a small set of unit tests around source-resolution and
// device-lookup translation paths.
//
// Responsibilities:
//   • Resolve CaptureSource / camera / microphone identifiers via Sendable
//     lookups so failures translate to CaptureError.sourceUnavailable.
//   • Configure SCStream + (optionally) AVCaptureSession.
//   • Forward sample buffers to the CaptureSink (set by §4.6's
//     AssetWriterPipeline; nil-sink is supported for headless smoke tests).
//   • Yield CaptureError onto `errors` for SCStream/AV runtime failures so
//     CaptureSession's monitor task can transition to .failed.
//   • Latch the host-clock time of the first observed sample and return it
//     as the captureStart RationalTime — the editor uses this to align the
//     parallel screen / cam / mic files (HANDOFF §6.5).
//
// Single-use per the protocol contract: a fresh instance per recording.
public actor LiveCaptureBackend: CaptureBackend {
    public nonisolated let errors: AsyncStream<CaptureError>
    private let errorContinuation: AsyncStream<CaptureError>.Continuation

    private let sink: (any CaptureSink)?
    private let shareableContent: ShareableContentLookup
    private let deviceLookup: CaptureDeviceLookup
    private let firstSampleTimeout: TimeInterval

    private var plan: CapturePlan?
    private var stream: SCStream?
    private var streamBridge: SCStreamBridge?
    private var avSession: AVCaptureSession?
    private var avBridge: AVOutputBridge?
    private var avRuntimeErrorObserver: NSObjectProtocol?
    private var firstSampleTime: RationalTime?
    private var firstSampleWaiters: [CheckedContinuation<RationalTime, Error>] = []
    /// AVCaptureSession-specific first-sample observer. The global
    /// `firstSampleTime` latches on WHICHEVER bridge fires first (typically
    /// SCStream), so we can't reuse it to gate "wait for camera warm-up
    /// before SCStream starts". This separate slot tracks the first AV
    /// sample only.
    private var firstAVSampleTime: RationalTime?
    private var firstAVSampleWaiters: [CheckedContinuation<RationalTime, Error>] = []
    private var sessionStartWallClock: Date?

    public init(
        sink: (any CaptureSink)? = nil,
        shareableContent: ShareableContentLookup = .live,
        deviceLookup: CaptureDeviceLookup = .live,
        firstSampleTimeout: TimeInterval = 5
    ) {
        self.sink = sink
        self.shareableContent = shareableContent
        self.deviceLookup = deviceLookup
        self.firstSampleTimeout = firstSampleTimeout
        var continuation: AsyncStream<CaptureError>.Continuation!
        self.errors = AsyncStream { continuation = $0 }
        self.errorContinuation = continuation
    }

    public func start(plan: CapturePlan) async throws -> RationalTime {
        guard self.plan == nil else {
            throw CaptureError.invalidState(message: "LiveCaptureBackend is single-use; start() called twice")
        }
        self.plan = plan
        log.info("start sessionID=\(plan.sessionID, privacy: .public) source=\(String(describing: plan.source), privacy: .public) camera=\(plan.camera ?? "nil", privacy: .public) audio=\(String(describing: plan.audio), privacy: .public) sysAudio=\(plan.includeSystemAudio) sinkConfigured=\(self.sink != nil)")

        let display: SCDisplay
        switch plan.source {
        case .display(let id):
            display = try await shareableContent.display(id)
        case .window:
            throw CaptureError.sourceUnavailable(message: "Window capture is not in v0.1 (Phase 4)")
        case .area:
            throw CaptureError.sourceUnavailable(message: "Area capture is not in v0.1 (Phase 4)")
        case .device:
            throw CaptureError.sourceUnavailable(message: "Continuity Camera capture is not in v0.1 (Phase 4)")
        }

        var camera: AVCaptureDevice?
        if let camID = plan.camera {
            guard let device = deviceLookup.camera(camID) else {
                throw CaptureError.sourceUnavailable(message: "Camera \(camID) not found")
            }
            camera = device
        }
        var microphone: AVCaptureDevice?
        if let micID = plan.audio.deviceUniqueID {
            guard let device = deviceLookup.microphone(micID) else {
                throw CaptureError.sourceUnavailable(message: "Microphone \(micID) not found")
            }
            microphone = device
        }

        let config = SCStreamConfiguration()
        // Capture at native pixel resolution, then cap at 1920 max edge for
        // v0.1. SCDisplay's width/height are in points; ×2 is Retina-native.
        // Without the cap, a Retina display produces 5K+ frames at 60fps
        // which the default H.264 encoder choked on with
        // AVFoundationErrorDomain -11800 / NSOSStatus -16122 ("operation
        // could not be completed") after ~0.5s of recording.
        // Phase 4 revisits true-pixel capture with an explicit bitrate
        // ladder; v0.1 is "it records at all".
        let nativeWidth = display.width * 2
        let nativeHeight = display.height * 2
        let maxEdge = 1920
        let downscale = max(1.0, max(Double(nativeWidth), Double(nativeHeight)) / Double(maxEdge))
        // Round to even — H.264 chroma subsampling (YUV420) requires
        // even-numbered width/height. Off-by-one odd dimensions can be
        // implicated in encoder rejection.
        config.width = (Int(Double(nativeWidth) / downscale) / 2) * 2
        config.height = (Int(Double(nativeHeight) / downscale) / 2) * 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        // Pixel format: bi-planar NV12 (luma + interleaved chroma) is what
        // the H.264 encoder consumes natively. SCStream's default is BGRA,
        // forcing a per-frame BGRA→YUV420 conversion inside the encoder
        // pipeline that's been implicated in iteration-7/8's screen.mov
        // immediate-failure (cam.mov works because cameras already deliver
        // YUV-family formats — same H.264 settings, different source format,
        // different outcome).
        config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        // sRGB color space avoids any wide-gamut conversion the encoder may
        // refuse. Display P3 / extended-range is a Phase 4 concern.
        config.colorSpaceName = CGColorSpace.sRGB
        config.capturesAudio = plan.includeSystemAudio
        config.excludesCurrentProcessAudio = true
        config.queueDepth = 6
        // Phase 3c — suppress the OS cursor in captured frames so the
        // compositor can draw its own scalable cursor sprite on top using
        // the mouse-trajectory sidecar. The asset is stamped
        // `cursorRenderedSynthetically=true` at save time
        // (RecordingService); legacy recordings (this flag was always-on
        // before this change) keep the OS cursor baked in and the
        // compositor skips the synthetic pass for them, avoiding a double
        // cursor.
        config.showsCursor = false
        log.info("SCStreamConfiguration native=\(nativeWidth)x\(nativeHeight) capped=\(config.width)x\(config.height) (downscale=\(downscale)) pixelFormat=NV12-videoRange showsCursor=false")
        let excludedApps: [SCRunningApplication]
        if plan.excludedBundleIdentifiers.isEmpty {
            excludedApps = []
        } else {
            // Best-effort — if SCShareableContent doesn't list the apps we
            // asked for, exclusion silently degrades to "they appear in
            // the recording", which is recoverable. A throw here would
            // be a worse user experience than recording with the picker
            // visible.
            excludedApps = (try? await shareableContent.applications(plan.excludedBundleIdentifiers)) ?? []
            log.info("excludingApplications=\(excludedApps.map { $0.bundleIdentifier }, privacy: .public) requestedIDs=\(plan.excludedBundleIdentifiers, privacy: .public)")
        }
        let filter = SCContentFilter(
            display: display,
            excludingApplications: excludedApps,
            exceptingWindows: []
        )

        let scBridge = SCStreamBridge(
            sink: sink,
            errorContinuation: errorContinuation,
            onFirstSample: { [weak self] hostTime in
                Task { await self?.recordFirstSample(hostTime) }
            }
        )
        let stream = SCStream(filter: filter, configuration: config, delegate: scBridge)
        do {
            try stream.addStreamOutput(scBridge, type: .screen, sampleHandlerQueue: scBridge.queue)
            if plan.includeSystemAudio {
                try stream.addStreamOutput(scBridge, type: .audio, sampleHandlerQueue: scBridge.queue)
            }
        } catch {
            throw CaptureError.streamFailed(message: "Failed to add SCStream output: \(error.localizedDescription)")
        }

        var session: AVCaptureSession?
        var bridge: AVOutputBridge?
        if camera != nil || microphone != nil {
            let s = AVCaptureSession()
            s.beginConfiguration()
            let outBridge = AVOutputBridge(
                sink: sink,
                errorContinuation: errorContinuation,
                onFirstSample: { [weak self] hostTime in
                    Task {
                        await self?.recordFirstSample(hostTime)
                        await self?.recordFirstAVSample(hostTime)
                    }
                }
            )
            do {
                if let cam = camera {
                    let input = try AVCaptureDeviceInput(device: cam)
                    guard s.canAddInput(input) else {
                        throw CaptureError.sourceUnavailable(message: "Camera \(cam.uniqueID) cannot be added to AVCaptureSession")
                    }
                    s.addInput(input)
                    let output = AVCaptureVideoDataOutput()
                    output.alwaysDiscardsLateVideoFrames = false
                    output.setSampleBufferDelegate(outBridge, queue: outBridge.videoQueue)
                    guard s.canAddOutput(output) else {
                        throw CaptureError.sourceUnavailable(message: "AVCaptureVideoDataOutput cannot be added")
                    }
                    s.addOutput(output)
                }
                if let mic = microphone {
                    let input = try AVCaptureDeviceInput(device: mic)
                    guard s.canAddInput(input) else {
                        throw CaptureError.sourceUnavailable(message: "Microphone \(mic.uniqueID) cannot be added to AVCaptureSession")
                    }
                    s.addInput(input)
                    let output = AVCaptureAudioDataOutput()
                    // Request INTERLEAVED Float32 explicitly. Default delivery
                    // is non-interleaved (separate buffer per channel), which
                    // the AAC encoder's AudioConverter has been observed to
                    // mid-stream-fail on (mic.caf appended 56 then started
                    // rejecting in iteration 8).
                    //
                    // Channel count + sample rate are derived from the device's
                    // native format, then constrained to a shape the downstream
                    // AAC encoder (in AssetWriterPipeline) can directly accept:
                    //
                    //   • channels: min(native, 2). Iter #12: never UP-mix a
                    //     mono mic to stereo here — AVCaptureSession's internal
                    //     AudioConverter zero-fills the synthesised channel and
                    //     mic.caf comes out silent. Down-mixing 4ch / 6ch USB
                    //     interfaces to stereo via the same converter is fine.
                    //   • sampleRate: native if it's already in the AAC-LC
                    //     supported set {8,11.025,12,16,22.05,24,32,44.1,48}
                    //     kHz, otherwise the nearest supported rate. Letting
                    //     AVCaptureSession's converter do this snap is more
                    //     reliable than asking AVAssetWriterInput's AAC encoder
                    //     to resample at startWriting time — exotic rates
                    //     (88.2/96/192 kHz pro mics) caused -11861
                    //     (AVErrorEncoderDecoderConfigurationNotAvailable) at
                    //     startWriting, which then cascaded through
                    //     AssetWriterPipeline's per-track failure path and
                    //     dropped screen.mov frames too (2026-05-04).
                    var nativeChannels = 1
                    var nativeRate: Double = 48_000
                    if let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(mic.activeFormat.formatDescription)?.pointee {
                        nativeChannels = Int(asbd.mChannelsPerFrame)
                        nativeRate = asbd.mSampleRate
                    }
                    let outChannels = max(1, min(nativeChannels, 2))
                    let aacRates: [Double] = [8000, 11025, 12000, 16000, 22050, 24000, 32000, 44100, 48000]
                    let outRate: Double
                    if aacRates.contains(nativeRate) {
                        outRate = nativeRate
                    } else {
                        outRate = aacRates.min(by: { abs($0 - nativeRate) < abs($1 - nativeRate) }) ?? 48_000
                    }
                    output.audioSettings = [
                        AVFormatIDKey: kAudioFormatLinearPCM,
                        AVLinearPCMIsFloatKey: true,
                        AVLinearPCMBitDepthKey: 32,
                        AVLinearPCMIsNonInterleaved: false,
                        AVLinearPCMIsBigEndianKey: false,
                        AVNumberOfChannelsKey: outChannels,
                        AVSampleRateKey: outRate
                    ]
                    log.info("Mic audioSettings: native ch=\(nativeChannels) rate=\(nativeRate) → out ch=\(outChannels) rate=\(outRate)")
                    output.setSampleBufferDelegate(outBridge, queue: outBridge.audioQueue)
                    guard s.canAddOutput(output) else {
                        throw CaptureError.sourceUnavailable(message: "AVCaptureAudioDataOutput cannot be added")
                    }
                    s.addOutput(output)
                }
            } catch let captureError as CaptureError {
                s.commitConfiguration()
                throw captureError
            } catch {
                s.commitConfiguration()
                throw CaptureError.sourceUnavailable(message: "AVCaptureSession setup failed: \(error.localizedDescription)")
            }
            s.commitConfiguration()
            session = s
            bridge = outBridge

            let cont = errorContinuation
            avRuntimeErrorObserver = NotificationCenter.default.addObserver(
                forName: .AVCaptureSessionRuntimeError,
                object: s,
                queue: nil
            ) { note in
                let underlying = note.userInfo?[AVCaptureSessionErrorKey] as? Error
                cont.yield(.streamFailed(message: underlying?.localizedDescription ?? "AVCaptureSession runtime error"))
            }
        }

        // Capture-pipeline ordering fix (2026-05-27): start AVCaptureSession
        // FIRST and wait for its first sample BEFORE starting SCStream.
        //
        // The previous order (SCStream first, then session.startRunning)
        // produced cam / mic files that were noticeably shorter than the
        // screen recording: SCStream emits its first sample within ~200ms
        // of `startCapture()`, but the camera + microphone need ~1–2 s of
        // hardware warm-up after `session.startRunning()` returns before
        // the AVOutputBridge sees its first sample. The AssetWriter for
        // each track starts its session at THAT track's first PTS, so
        // the cam.mov / mic.caf files captured (T_stop − T_first_cam) =
        // (T_stop − T_screen_first − warmupGap) of content while
        // screen.mov captured the full (T_stop − T_screen_first).
        //
        // Serializing the warm-up here means cam/mic are already
        // producing samples by the time SCStream starts, so all four
        // tracks land first samples within ~tens of ms of each other.
        // The user-visible cost is a ~1–2 s wait between "Record" being
        // pressed and recording actually starting; RecordingService's
        // `.preparing` phase already surfaces this. Acceptable trade-off
        // for tracks-of-equal-length on the timeline.
        //
        // If there's no AVCaptureSession (screen-only recording), skip
        // straight to SCStream.
        self.stream = stream
        self.streamBridge = scBridge
        self.avSession = session
        self.avBridge = bridge

        if let session = session {
            session.startRunning()
            log.info("AVCaptureSession.startRunning called isRunning=\(session.isRunning) inputs=\(session.inputs.count) outputs=\(session.outputs.count)")
            // Wait for the AVCaptureSession's first sample before kicking
            // off SCStream. Bounded by `firstSampleTimeout` (default 5s)
            // so an unresponsive camera doesn't hang the recording start
            // forever; on timeout we proceed with SCStream anyway and
            // accept the misalignment for that recording.
            do {
                let avFirst = try await awaitFirstAVSample()
                log.info("AVCaptureSession first sample observed at PTS \(avFirst.value)/\(avFirst.timescale); proceeding to SCStream")
            } catch {
                log.notice("AVCaptureSession first-sample wait failed (\(String(describing: error), privacy: .public)); starting SCStream anyway")
            }
        }

        do {
            try await stream.startCapture()
            log.info("SCStream.startCapture returned (capturesAudio=\(plan.includeSystemAudio))")
        } catch {
            log.error("SCStream.startCapture threw: \(error.localizedDescription, privacy: .public)")
            throw Self.mapSCStreamStartError(error)
        }

        self.sessionStartWallClock = Date()

        let firstSample = try await awaitFirstSample()
        log.info("first sample latched at PTS \(firstSample.value)/\(firstSample.timescale)")
        return firstSample
    }

    public func stop() async throws -> CaptureSummary {
        guard let plan = self.plan else {
            throw CaptureError.invalidState(message: "stop() before start() on LiveCaptureBackend")
        }
        log.info("stop entered sessionID=\(plan.sessionID, privacy: .public)")

        if let observer = avRuntimeErrorObserver {
            NotificationCenter.default.removeObserver(observer)
            avRuntimeErrorObserver = nil
        }
        if let session = avSession, session.isRunning {
            session.stopRunning()
        }
        if let stream = stream {
            do {
                try await stream.stopCapture()
            } catch {
                log.error("SCStream.stopCapture threw: \(error.localizedDescription, privacy: .public)")
                errorContinuation.yield(.streamFailed(message: "stopCapture: \(error.localizedDescription)"))
            }
        }
        errorContinuation.finish()

        let sinkSummary: CaptureSinkSummary
        do {
            sinkSummary = try await sink?.finish() ?? .empty
        } catch {
            log.error("sink.finish threw: \(error.localizedDescription, privacy: .public)")
            sinkSummary = .empty
        }
        log.info("sink.finish returned screenDur=\(sinkSummary.screenDuration?.seconds ?? -1) camDur=\(sinkSummary.camDuration?.seconds ?? -1) micDur=\(sinkSummary.micDuration?.seconds ?? -1) trackStatsKeys=\(sinkSummary.trackStats.keys.map { String(describing: $0) }.joined(separator: ","), privacy: .public) writerErrors=\(sinkSummary.writerErrors.count)")
        for err in sinkSummary.writerErrors {
            log.error("writerError: \(err, privacy: .public)")
        }
        let captureStart = firstSampleTime ?? .zero
        let duration: RationalTime
        if let started = sessionStartWallClock {
            duration = .seconds(Date().timeIntervalSince(started))
        } else {
            duration = .zero
        }
        return CaptureSummary(
            outputs: plan.outputs,
            captureStart: captureStart,
            duration: duration,
            screenDuration: sinkSummary.screenDuration,
            camDuration: sinkSummary.camDuration,
            micDuration: sinkSummary.micDuration,
            sysAudioDuration: sinkSummary.sysAudioDuration,
            trackStats: sinkSummary.trackStats,
            writerErrors: sinkSummary.writerErrors
        )
    }

    private func recordFirstSample(_ hostTime: RationalTime) {
        guard firstSampleTime == nil else { return }
        firstSampleTime = hostTime
        let waiters = firstSampleWaiters
        firstSampleWaiters = []
        for w in waiters {
            w.resume(returning: hostTime)
        }
    }

    private func awaitFirstSample() async throws -> RationalTime {
        if let existing = firstSampleTime { return existing }
        let timeout = firstSampleTimeout
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<RationalTime, Error>) in
            firstSampleWaiters.append(cont)
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                await self?.failPendingFirstSampleWaiters()
            }
        }
    }

    private func failPendingFirstSampleWaiters() {
        guard firstSampleTime == nil else { return }
        let waiters = firstSampleWaiters
        firstSampleWaiters = []
        let timeout = firstSampleTimeout
        for w in waiters {
            w.resume(throwing: CaptureError.streamFailed(message: "No sample buffer observed within \(timeout)s of stream start"))
        }
    }

    // MARK: - AVCaptureSession-specific first-sample tracking

    private func recordFirstAVSample(_ hostTime: RationalTime) {
        guard firstAVSampleTime == nil else { return }
        firstAVSampleTime = hostTime
        let waiters = firstAVSampleWaiters
        firstAVSampleWaiters = []
        for w in waiters {
            w.resume(returning: hostTime)
        }
    }

    private func awaitFirstAVSample() async throws -> RationalTime {
        if let existing = firstAVSampleTime { return existing }
        let timeout = firstSampleTimeout
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<RationalTime, Error>) in
            firstAVSampleWaiters.append(cont)
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                await self?.failPendingFirstAVSampleWaiters()
            }
        }
    }

    private func failPendingFirstAVSampleWaiters() {
        guard firstAVSampleTime == nil else { return }
        let waiters = firstAVSampleWaiters
        firstAVSampleWaiters = []
        let timeout = firstSampleTimeout
        for w in waiters {
            w.resume(throwing: CaptureError.streamFailed(message: "No AVCaptureSession sample observed within \(timeout)s of session.startRunning()"))
        }
    }

    static func mapSCStreamStartError(_ error: Error) -> CaptureError {
        let nsError = error as NSError
        if nsError.domain == SCStreamErrorDomain {
            if nsError.code == SCStreamError.userDeclined.rawValue {
                return .notPermitted
            }
            return .streamFailed(message: nsError.localizedDescription)
        }
        return .streamFailed(message: nsError.localizedDescription)
    }
}

#endif
