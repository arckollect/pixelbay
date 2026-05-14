import Foundation

// Status the coordinator surfaces to the UI.
//
// `requiresRelaunch` is a Screen-Recording-specific subtlety: macOS may report
// the permission as granted in System Settings before our process is allowed
// to actually use it. The fix is to relaunch the app — but the user has to be
// told that explicitly, so we model it as its own state rather than collapsing
// it into `granted`.
//
// `denied` only meaningfully applies to Camera and Microphone, where
// `AVCaptureDevice.authorizationStatus(for:)` exposes a clear "denied" case
// distinct from "not yet decided." Screen Recording and Accessibility have no
// denied/notDetermined distinction at the API level, so we map both to
// `notDetermined` until preflight returns true.
public enum PermissionStatus: String, Sendable, Hashable, Codable {
    case notDetermined
    case granted
    case denied
    case requiresRelaunch
}
