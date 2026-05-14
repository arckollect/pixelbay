import Foundation

// The set of macOS permissions Pixelbay cares about. Order in `allCases` is
// also the row order in the onboarding UI: most impactful first.
//
// `accessibility` is optional in Phase 1 (it gates `CGEventTap` for click /
// keystroke logging in `PixelbayInputCapture`). It is shown in the onboarding
// list so the user understands what the auto-zoom feature will eventually
// need, but the app remains usable without it.
public enum PermissionKind: String, Sendable, Hashable, CaseIterable {
    case screenRecording
    case camera
    case microphone
    case accessibility

    public var humanReadableName: String {
        switch self {
        case .screenRecording: return "Screen Recording"
        case .camera: return "Camera"
        case .microphone: return "Microphone"
        case .accessibility: return "Accessibility"
        }
    }

    public var rationale: String {
        switch self {
        case .screenRecording:
            return "Required to record the contents of your screen."
        case .camera:
            return "Optional. Used to record your webcam alongside the screen."
        case .microphone:
            return "Optional. Used to record your voice alongside the screen."
        case .accessibility:
            return "Optional. Lets Pixelbay log click positions for the auto-zoom feature."
        }
    }

    // Whether the app can usefully launch without this permission. Only Screen
    // Recording is hard-required for v0.1; the rest are degraded-mode capable.
    public var isRequiredForLaunch: Bool {
        self == .screenRecording
    }
}
