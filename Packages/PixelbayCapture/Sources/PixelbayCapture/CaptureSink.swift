import CoreMedia
import Foundation
import PixelbayCore

// Where LiveCaptureBackend hands its sample buffers. PixelbayRecording's
// AssetWriterPipeline (§4.6) is the production conformance; tests use an
// in-memory fake. Defined in PixelbayCapture (and not in PixelbayRecording)
// so the two modules don't form a hard dependency cycle.
//
// `append` is synchronous because SCStream and AVCaptureSession invoke their
// delegates on a serial sample-buffer queue and we want zero extra hops on
// the hot path. Conformances must be cheap and re-entrant; long work belongs
// inside an internal AVAssetWriter or background queue.
//
// `finish` is async because finalising AVAssetWriters takes real time
// (writer.finishWriting is asynchronous). It returns the per-track durations
// the backend needs to populate CaptureSummary.
public protocol CaptureSink: Sendable {
    func append(_ sampleBuffer: CMSampleBuffer, on track: CaptureTrack)
    func finish() async throws -> CaptureSinkSummary
}

// Identifier the sink uses to route sample buffers to per-output-file
// AVAssetWriters. As of iter 10, each track is its own file: .screenAudio
// routes to sysaudio-<id>.caf (was a 2nd track inside screen.mov pre-iter-10
// but the AVAssetWriter dual-track encoder kept failing while the equivalent
// single-track writers worked — see AssetWriterPipeline + HANDOFF §3.16).
public enum CaptureTrack: Sendable, Hashable {
    case screenVideo
    case screenAudio
    case camVideo
    case micAudio
}

// Per-file durations populated by the sink's finish(). The backend folds
// these into CaptureSummary alongside the wall-clock duration it tracks
// directly.
public struct CaptureSinkSummary: Sendable, Equatable {
    public var screenDuration: RationalTime?
    public var camDuration: RationalTime?
    public var micDuration: RationalTime?
    public var sysAudioDuration: RationalTime?
    // Per-CaptureTrack diagnostic counters. Empty when the sink doesn't emit
    // them. AssetWriterPipeline populates these so the smoke harness can show
    // sample-level health (how many appends succeeded vs. failed vs. dropped
    // for not-ready) without re-running the recording.
    public var trackStats: [CaptureTrack: TrackStats]
    // Per-writer / per-append error descriptions captured during finish().
    // Surfaced as Strings (not Errors) to keep the summary Sendable and
    // serialisable. Populated when the sink encountered a writer failure but
    // wants to return stats anyway — earlier behaviour was to throw, which
    // dropped the stats dictionary on the floor in LiveCaptureBackend.stop()'s
    // catch fallback.
    public var writerErrors: [String]

    public init(
        screenDuration: RationalTime? = nil,
        camDuration: RationalTime? = nil,
        micDuration: RationalTime? = nil,
        sysAudioDuration: RationalTime? = nil,
        trackStats: [CaptureTrack: TrackStats] = [:],
        writerErrors: [String] = []
    ) {
        self.screenDuration = screenDuration
        self.camDuration = camDuration
        self.micDuration = micDuration
        self.sysAudioDuration = sysAudioDuration
        self.trackStats = trackStats
        self.writerErrors = writerErrors
    }

    public static let empty = CaptureSinkSummary()
}

public struct TrackStats: Sendable, Equatable {
    // Samples for which AVAssetWriterInput.append returned true.
    public var appendedCount: Int
    // input.append returned false — the writer rejected the sample (PTS jitter,
    // format mismatch, encoder failure). The first occurrence is usually the
    // root cause; subsequent failures cascade.
    public var appendFailedCount: Int
    // input.isReadyForMoreMediaData was false — the writer is backpressured.
    // Common when the encoder can't keep up; the bridge drops rather than
    // blocks the SCStream / AVCaptureSession queue.
    public var droppedNotReadyCount: Int
    // Samples buffered before AVAssetWriter.startWriting() that we kept and
    // drained in order. Non-zero only on multi-input writers (screen.mov with
    // includeSystemAudio = true).
    public var bufferedThenAppendedCount: Int

    public init(
        appendedCount: Int = 0,
        appendFailedCount: Int = 0,
        droppedNotReadyCount: Int = 0,
        bufferedThenAppendedCount: Int = 0
    ) {
        self.appendedCount = appendedCount
        self.appendFailedCount = appendFailedCount
        self.droppedNotReadyCount = droppedNotReadyCount
        self.bufferedThenAppendedCount = bufferedThenAppendedCount
    }
}
