import Foundation
import PixelbayCore

// Sendable seam over the framework objects that own a capture session's
// runtime state — SCStream and AVCaptureSession in the live impl, an
// in-memory fake in tests.
//
// Same intent as PixelbayPermissions.PermissionProbe but expressed as a
// protocol because a backend must hold mutable per-session state across
// start / stop / mid-flight error handling, which is awkward to model as a
// struct of standalone closures. Conforming types are typically actors.
//
// The session interacts with the backend in a strict order:
//
//   1. await backend.start(plan:)   →  returns the absolute capture-start
//      time (host clock) once the first sample buffer is observed. Throws
//      CaptureError if SCStream / AVCaptureSession setup fails.
//
//   2. for await error in backend.errors  →  the session monitors this in
//      the background. SCStream's `didStopWithError` (window closed mid-
//      recording, GPU reset, etc.) is delivered here. The session
//      transitions to .failed on the first event.
//
//   3. await backend.stop()          →  flushes writers, returns the
//      summary (durations, outputs). Throws if finalising fails.
//
// A backend instance is single-use: one start, one stop. The session
// constructs a fresh backend per recording.
public protocol CaptureBackend: Sendable {
    func start(plan: CapturePlan) async throws -> RationalTime
    func stop() async throws -> CaptureSummary
    var errors: AsyncStream<CaptureError> { get }
}
