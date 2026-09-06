import Foundation

// PermissionCoordinator owns the per-permission state machine. It is an actor
// because permission state is read from multiple call sites (onboarding UI,
// pre-capture picker, capture session, recovery prompt) and must not race.
//
// The Screen-Recording state machine is the subtle bit. macOS reports the
// permission via `CGPreflightScreenCaptureAccess()`, but a granted permission
// does NOT take effect for the running process until relaunch — `SCStream`
// will fail until the next process launch. To surface this clearly to the
// user we model `requiresRelaunch` as its own status:
//
//   * preflight=true at first observation     -> .granted   (caller already relaunched)
//   * preflight=false then later true         -> .requiresRelaunch
//   * preflight stays false                   -> .notDetermined
//
// Camera and Microphone use AVFoundation's authorization status directly
// (probe maps the AVAuthorizationStatus enum to PermissionStatus). Accessibility
// has only "trusted" or "not", with no denied state — we treat untrusted as
// notDetermined so the UI keeps offering the Grant button.
public actor PermissionCoordinator {
    public private(set) var statuses: [PermissionKind: PermissionStatus]
    private let probe: PermissionProbe

    // Captured the first time we observe screen-recording preflight in this
    // process lifetime. Used to detect the false→true transition that means
    // "user just granted in Settings, app needs to relaunch."
    private var initialScreenRecordingPreflight: Bool?

    public init(probe: PermissionProbe) {
        self.probe = probe
        self.statuses = Dictionary(
            uniqueKeysWithValues: PermissionKind.allCases.map { ($0, .notDetermined) }
        )
    }

    // Re-probe every permission and update the cached status map. Cheap; fine
    // to call from a SwiftUI .task or a 1Hz timer while the onboarding view is
    // visible. Returns the updated map for convenience.
    @discardableResult
    public func refresh() -> [PermissionKind: PermissionStatus] {
        let preflight = probe.screenRecordingPreflight()
        if initialScreenRecordingPreflight == nil {
            initialScreenRecordingPreflight = preflight
        }
        statuses[.screenRecording] = computeScreenRecordingStatus(
            preflight: preflight,
            initial: initialScreenRecordingPreflight ?? false
        )

        statuses[.camera] = probe.cameraStatus()
        statuses[.microphone] = probe.microphoneStatus()
        statuses[.accessibility] = probe.accessibilityTrusted() ? .granted : .notDetermined

        return statuses
    }

    // Trigger the system grant flow for `kind`. Behavior varies by permission:
    //
    //   * camera / microphone — async AVCaptureDevice.requestAccess; resolves
    //     when the user dismisses the prompt.
    //   * screen recording — CGRequestScreenCaptureAccess prompts once on a
    //     fresh user account, then opens System Settings on subsequent calls.
    //     Caller should follow up by polling refresh() while the onboarding
    //     view is visible.
    //   * accessibility — AXIsProcessTrustedWithOptions(prompt) registers the
    //     app in the Accessibility list and shows the system dialog; the user
    //     still flips the toggle in Settings, and refresh() polling picks it
    //     up (AXIsProcessTrusted reflects the change live, no relaunch).
    //
    // Returns the post-request status for the requested kind. The full status
    // map is also refreshed as a side effect.
    @discardableResult
    public func request(_ kind: PermissionKind) async -> PermissionStatus {
        switch kind {
        case .screenRecording:
            _ = probe.requestScreenRecording()
            return refresh()[.screenRecording] ?? .notDetermined
        case .camera:
            let result = await probe.requestCamera()
            statuses[.camera] = result
            return result
        case .microphone:
            let result = await probe.requestMicrophone()
            statuses[.microphone] = result
            return result
        case .accessibility:
            _ = probe.requestAccessibility()
            return refresh()[.accessibility] ?? .notDetermined
        }
    }

    // Open the relevant System Settings privacy pane for the user to flip the
    // toggle manually. Used as the secondary path when the OS doesn't offer a
    // programmatic prompt (or has already shown one).
    public func openSettings(for kind: PermissionKind) {
        switch kind {
        case .screenRecording: probe.openScreenRecordingSettings()
        case .camera: probe.openCameraSettings()
        case .microphone: probe.openMicrophoneSettings()
        case .accessibility: probe.openAccessibilitySettings()
        }
    }

    // True if any permission is in `.requiresRelaunch`. The onboarding view
    // surfaces a "Quit & Relaunch" CTA in that case.
    public var anyRequiresRelaunch: Bool {
        statuses.values.contains(.requiresRelaunch)
    }

    // True if all permissions marked `isRequiredForLaunch` are granted. The
    // onboarding scene dismisses itself when this flips to true.
    public var requiredPermissionsSatisfied: Bool {
        for kind in PermissionKind.allCases where kind.isRequiredForLaunch {
            if statuses[kind] != .granted { return false }
        }
        return true
    }

    private func computeScreenRecordingStatus(preflight: Bool, initial: Bool) -> PermissionStatus {
        switch (preflight, initial) {
        case (true, true): return .granted
        case (true, false): return .requiresRelaunch
        case (false, _): return .notDetermined
        }
    }
}
