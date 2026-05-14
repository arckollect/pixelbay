import Foundation

// Errors surfaced by CaptureSession. Equatable so tests can match on cases;
// the associated `String` payload on backend-side failures is the underlying
// error's localizedDescription (lossy but sufficient for state-machine asserts
// and user-facing surfacing).
public enum CaptureError: Error, Sendable, Equatable {
    // Caller invoked start() / stop() in a state where it's not legal — e.g.
    // start() while already recording, or stop() before start.
    case invalidState(message: String)

    // ScreenCaptureKit returned `notAllowed` when starting the stream. The
    // session does NOT preflight permissions itself (per HANDOFF §4.5); the
    // app layer is responsible for gating start() on
    // PermissionCoordinator.statuses[.screenRecording] == .granted. This
    // surfaces only when permission was revoked between the gate and start.
    case notPermitted

    // The requested SCDisplay / SCWindow / AVCaptureDevice could not be
    // resolved from its identifier (display unplugged, window closed, mic
    // unplugged between picker and start).
    case sourceUnavailable(message: String)

    // The .pixelbay bundle path is missing or the media/ subdirectory
    // could not be created.
    case bundleUnavailable(message: String)

    // Catch-all for SCStream / AVAssetWriter / AVCaptureSession failures
    // that happen mid-recording — including SCStream's didStopWithError
    // (window closed mid-recording, GPU reset, etc.).
    case streamFailed(message: String)
}

extension CaptureError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .invalidState(let m): return "Capture invalid state: \(m)"
        case .notPermitted: return "Capture not permitted (Screen Recording was revoked)."
        case .sourceUnavailable(let m): return "Capture source unavailable: \(m)"
        case .bundleUnavailable(let m): return "Capture bundle unavailable: \(m)"
        case .streamFailed(let m): return "Capture stream failed: \(m)"
        }
    }
}
