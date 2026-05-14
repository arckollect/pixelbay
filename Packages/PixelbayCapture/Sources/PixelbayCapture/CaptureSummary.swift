import Foundation
import PixelbayCore

// Result of a successful CaptureSession.stop(). The recording pipeline
// (PixelbayRecording.AssetWriterPipeline, §4.6) populates this with
// `captureStart` (the absolute host-clock time of the first sample) and the
// per-file durations after all writers flush. Phase 2's editor consumes
// these to construct MediaAsset records for the project model.
public struct CaptureSummary: Sendable, Equatable {
    public var outputs: CaptureOutputs
    // Absolute time of recording-start, expressed via the host clock used by
    // both SCStream and AVCaptureSession sample-buffer timestamps. The editor
    // uses this to align the parallel files (HANDOFF §6.5).
    public var captureStart: RationalTime
    // Total wall-clock duration from start() to the moment all writers
    // finalised. Reflects what the user experienced; the per-file
    // nativeDuration values may be slightly shorter due to writer flush.
    public var duration: RationalTime
    public var screenDuration: RationalTime?
    public var camDuration: RationalTime?
    public var micDuration: RationalTime?
    public var sysAudioDuration: RationalTime?
    // Per-track sample-level stats from the recording sink (see TrackStats).
    // Empty when the sink doesn't emit them. Populated by AssetWriterPipeline
    // so the smoke harness / debug UI can show whether append failures or
    // backpressure dropped data sample-by-sample.
    public var trackStats: [CaptureTrack: TrackStats]
    // Mirrors CaptureSinkSummary.writerErrors — non-empty when the sink had
    // per-track writer failures during finalisation. Useful for surfacing in
    // a debug UI without re-running the recording.
    public var writerErrors: [String]

    public init(
        outputs: CaptureOutputs,
        captureStart: RationalTime,
        duration: RationalTime,
        screenDuration: RationalTime? = nil,
        camDuration: RationalTime? = nil,
        micDuration: RationalTime? = nil,
        sysAudioDuration: RationalTime? = nil,
        trackStats: [CaptureTrack: TrackStats] = [:],
        writerErrors: [String] = []
    ) {
        self.outputs = outputs
        self.captureStart = captureStart
        self.duration = duration
        self.screenDuration = screenDuration
        self.camDuration = camDuration
        self.micDuration = micDuration
        self.sysAudioDuration = sysAudioDuration
        self.trackStats = trackStats
        self.writerErrors = writerErrors
    }
}
