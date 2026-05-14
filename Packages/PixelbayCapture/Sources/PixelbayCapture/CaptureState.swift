import Foundation

// State machine for a CaptureSession.
//
//   .idle  ──start()──▶ .preparing ──backend resolved──▶ .recording
//                              │                                │
//                              └──────error or stop()──────────┐│
//                                                              ▼▼
//                                                        .stopping
//                                                              │
//                                                              ▼
//                                                       .stopped(summary)
//
// Any state can transition to .failed(error) if the backend errors mid-flight.
// .stopping/.stopped/.failed are terminal — a session is single-use; the
// caller constructs a fresh CaptureSession for the next recording.
public enum CaptureState: Sendable, Equatable {
    case idle
    case preparing
    case recording
    case stopping
    case stopped(summary: CaptureSummary)
    case failed(error: CaptureError)

    public var isTerminal: Bool {
        switch self {
        case .stopped, .failed: return true
        default: return false
        }
    }
}
