#if canImport(ScreenCaptureKit) && canImport(AVFoundation)
import AVFoundation
import CoreMedia
import Foundation
import OSLog
import PixelbayCore
import ScreenCaptureKit

private let log = Logger(subsystem: "com.pixelbay.PixelbayApp", category: "Bridges")

// NSObject delegate adapters for SCStream and AVCaptureSession. NSObject
// subclasses can't formally conform to Sendable so they're @unchecked
// Sendable; correctness rests on (a) only Sendable values being captured,
// and (b) `firstSampleObserved` mutation being serialised by the lock.
//
// Both bridges latch the host-clock time of the first sample they observe
// and fire a callback exactly once. CaptureSession needs the
// **earliest-arriving** first-sample across all bridges as the
// session-wide captureStart; LiveCaptureBackend.recordFirstSample(_:)
// applies the same latch-once rule so whichever bridge fires first wins.

final class SCStreamBridge: NSObject, SCStreamDelegate, SCStreamOutput, @unchecked Sendable {
    let queue = DispatchQueue(label: "com.pixelbay.capture.scstream", qos: .userInitiated)
    private let sink: (any CaptureSink)?
    private let errorContinuation: AsyncStream<CaptureError>.Continuation
    private let onFirstSample: @Sendable (RationalTime) -> Void
    private let lock = NSLock()
    private var firstSampleObserved = false

    init(
        sink: (any CaptureSink)?,
        errorContinuation: AsyncStream<CaptureError>.Continuation,
        onFirstSample: @escaping @Sendable (RationalTime) -> Void
    ) {
        self.sink = sink
        self.errorContinuation = errorContinuation
        self.onFirstSample = onFirstSample
        log.info("SCStreamBridge init sink=\(sink != nil ? "present" : "nil", privacy: .public)")
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        log.error("SCStream didStopWithError: \(error.localizedDescription, privacy: .public)")
        errorContinuation.yield(.streamFailed(message: error.localizedDescription))
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        let dataReady = CMSampleBufferDataIsReady(sampleBuffer)
        guard dataReady else {
            log.debug("SCStream sample dropped: !DataIsReady type=\(type.rawValue)")
            return
        }
        let track: CaptureTrack
        switch type {
        case .screen:
            // SCStream stamps every screen sample with an SCStreamFrameInfo
            // status attachment. `.complete` carries fresh pixel data; the
            // other statuses (`.idle`, `.blank`, `.suspended`, `.started`,
            // `.stopped`) are heartbeat / no-change markers whose image
            // buffers do not contain a freshly rendered frame. The H.264
            // encoder accepts the first batch of `.complete` frames during
            // initial activity, then rejects the first `.idle` that lands
            // when the screen quiets down — manifesting as
            // AVFoundationErrorDomain -11800 / NSOSStatus -16122 on
            // `input.append(_:)` and the writer transitioning to .failed
            // with every subsequent sample also failing (HANDOFF §3.16
            // iter #11). Filter to `.complete` here so only real frames
            // reach the writer.
            if !Self.isCompleteFrame(sampleBuffer) {
                return
            }
            track = .screenVideo
        case .audio: track = .screenAudio
        case .microphone:
            // SCStream gained a microphone output type in macOS 15. We
            // capture mic via AVCaptureSession, never SCStream — if this
            // case ever fires we've mis-wired addStreamOutput. Drop it.
            return
        @unknown default: return
        }

        var shouldFire = false
        lock.lock()
        if !firstSampleObserved {
            firstSampleObserved = true
            shouldFire = true
        }
        lock.unlock()
        if shouldFire {
            // SCStream stamps PTS with the host clock by default — no
            // CMSyncConvertTime hop needed (HANDOFF §6.5).
            let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            log.info("SCStreamBridge first sample track=\(String(describing: track), privacy: .public) pts=\(pts.value)/\(pts.timescale) sinkAvailable=\(self.sink != nil)")
            onFirstSample(RationalTime(value: pts.value, timescale: pts.timescale))
        }
        sink?.append(sampleBuffer, on: track)
    }

    static func isCompleteFrame(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let rawAttachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[CFString: Any]],
              let attachments = rawAttachments.first
        else {
            // No attachments at all — synthetic / test buffers fall here.
            // Treat as complete so we don't accidentally filter buffers a
            // future caller injects directly. Production SCStream samples
            // always carry attachments.
            return true
        }
        // SCStreamFrameInfo.status is a String-keyed enum; bridge through
        // the rawValue so this file does not require macOS 13's
        // SCStreamFrameInfo at compile time on test targets that link
        // PixelbayCapture but not ScreenCaptureKit.
        guard let statusValue = attachments[SCStreamFrameInfo.status.rawValue as CFString] as? Int,
              let status = SCFrameStatus(rawValue: statusValue)
        else {
            return true
        }
        if status != .complete {
            log.debug("SCStream screen sample dropped: status=\(status.rawValue)")
            return false
        }
        return true
    }
}

final class AVOutputBridge: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    let videoQueue = DispatchQueue(label: "com.pixelbay.capture.av-video", qos: .userInitiated)
    let audioQueue = DispatchQueue(label: "com.pixelbay.capture.av-audio", qos: .userInitiated)
    private let sink: (any CaptureSink)?
    private let errorContinuation: AsyncStream<CaptureError>.Continuation
    private let onFirstSample: @Sendable (RationalTime) -> Void
    private let sourceClock: CMClock?
    private let lock = NSLock()
    private var firstSampleObserved = false

    init(
        sink: (any CaptureSink)?,
        errorContinuation: AsyncStream<CaptureError>.Continuation,
        onFirstSample: @escaping @Sendable (RationalTime) -> Void,
        sourceClock: CMClock?
    ) {
        self.sink = sink
        self.errorContinuation = errorContinuation
        self.onFirstSample = onFirstSample
        self.sourceClock = sourceClock
        log.info("AVOutputBridge init sink=\(sink != nil ? "present" : "nil", privacy: .public) sourceClock=\(sourceClock != nil ? "present" : "nil", privacy: .public)")
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        let dataReady = CMSampleBufferDataIsReady(sampleBuffer)
        guard dataReady else {
            log.debug("AV sample dropped: !DataIsReady output=\(String(describing: type(of: output)), privacy: .public)")
            return
        }
        let track: CaptureTrack
        if output is AVCaptureVideoDataOutput {
            track = .camVideo
        } else if output is AVCaptureAudioDataOutput {
            track = .micAudio
        } else {
            return
        }

        var shouldFire = false
        lock.lock()
        if !firstSampleObserved {
            firstSampleObserved = true
            shouldFire = true
        }
        lock.unlock()
        if shouldFire {
            // AVCaptureSession's PTS is in its synchronizationClock domain;
            // convert to the host clock so it's directly comparable to
            // SCStream samples (HANDOFF §6.5).
            let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            let hostClock = CMClockGetHostTimeClock()
            let converted: CMTime
            if let src = sourceClock {
                converted = CMSyncConvertTime(pts, from: src, to: hostClock)
            } else {
                converted = pts
            }
            log.info("AVOutputBridge first sample track=\(String(describing: track), privacy: .public) pts=\(pts.value)/\(pts.timescale) sinkAvailable=\(self.sink != nil)")
            onFirstSample(RationalTime(value: converted.value, timescale: converted.timescale))
        }
        sink?.append(sampleBuffer, on: track)
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didDrop sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        log.notice("AV captureOutput didDrop sampleBuffer output=\(String(describing: type(of: output)), privacy: .public)")
    }
}

#endif
