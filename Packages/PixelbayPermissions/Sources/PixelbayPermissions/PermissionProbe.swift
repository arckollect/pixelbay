import Foundation
#if canImport(AVFoundation)
import AVFoundation
#endif
#if canImport(AppKit)
import AppKit
#endif
#if canImport(ApplicationServices)
import ApplicationServices
#endif
#if canImport(CoreGraphics)
import CoreGraphics
#endif

// Thin Sendable seam over the OS permission APIs. Pattern matches
// PixelbayCore.FileManagerWrapper: every actual TCC / AX / AVFoundation call
// goes through a closure here, and tests inject a mock that returns canned
// values so the coordinator state machine can be exercised without prompting
// the real macOS user.
//
// The `live` value below is the only place that touches the system frameworks.
// If you need to add a new permission, add a closure here and a corresponding
// case to PermissionKind, then handle it in PermissionCoordinator.refresh().
public struct PermissionProbe: Sendable {
    public var screenRecordingPreflight: @Sendable () -> Bool
    public var requestScreenRecording: @Sendable () -> Bool
    public var openScreenRecordingSettings: @Sendable () -> Void

    public var cameraStatus: @Sendable () -> PermissionStatus
    public var requestCamera: @Sendable () async -> PermissionStatus
    public var openCameraSettings: @Sendable () -> Void

    public var microphoneStatus: @Sendable () -> PermissionStatus
    public var requestMicrophone: @Sendable () async -> PermissionStatus
    public var openMicrophoneSettings: @Sendable () -> Void

    public var accessibilityTrusted: @Sendable () -> Bool
    public var openAccessibilitySettings: @Sendable () -> Void

    public init(
        screenRecordingPreflight: @escaping @Sendable () -> Bool,
        requestScreenRecording: @escaping @Sendable () -> Bool,
        openScreenRecordingSettings: @escaping @Sendable () -> Void,
        cameraStatus: @escaping @Sendable () -> PermissionStatus,
        requestCamera: @escaping @Sendable () async -> PermissionStatus,
        openCameraSettings: @escaping @Sendable () -> Void,
        microphoneStatus: @escaping @Sendable () -> PermissionStatus,
        requestMicrophone: @escaping @Sendable () async -> PermissionStatus,
        openMicrophoneSettings: @escaping @Sendable () -> Void,
        accessibilityTrusted: @escaping @Sendable () -> Bool,
        openAccessibilitySettings: @escaping @Sendable () -> Void
    ) {
        self.screenRecordingPreflight = screenRecordingPreflight
        self.requestScreenRecording = requestScreenRecording
        self.openScreenRecordingSettings = openScreenRecordingSettings
        self.cameraStatus = cameraStatus
        self.requestCamera = requestCamera
        self.openCameraSettings = openCameraSettings
        self.microphoneStatus = microphoneStatus
        self.requestMicrophone = requestMicrophone
        self.openMicrophoneSettings = openMicrophoneSettings
        self.accessibilityTrusted = accessibilityTrusted
        self.openAccessibilitySettings = openAccessibilitySettings
    }
}

#if canImport(AVFoundation) && canImport(AppKit)
extension PermissionProbe {
    // The default, OS-backed probe. Any test that constructs a coordinator
    // without an explicit probe will trigger real TCC prompts — don't do this
    // in unit tests; build a fake probe via PermissionProbe(screenRecordingPreflight:...)
    // with closures that return canned values.
    public static let live: PermissionProbe = PermissionProbe(
        screenRecordingPreflight: {
            CGPreflightScreenCaptureAccess()
        },
        requestScreenRecording: {
            // Triggers the system prompt the first time only; afterwards just
            // returns the current grant state. Subsequent grant-changes happen
            // in System Settings and surface via preflight.
            CGRequestScreenCaptureAccess()
        },
        openScreenRecordingSettings: {
            openSettings(pane: "Privacy_ScreenCapture")
        },
        cameraStatus: {
            mapAVAuthorization(AVCaptureDevice.authorizationStatus(for: .video))
        },
        requestCamera: {
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            // requestAccess resolves only after the user makes a choice; the
            // current authorizationStatus is now authoritative.
            return granted
                ? .granted
                : mapAVAuthorization(AVCaptureDevice.authorizationStatus(for: .video))
        },
        openCameraSettings: {
            openSettings(pane: "Privacy_Camera")
        },
        microphoneStatus: {
            mapAVAuthorization(AVCaptureDevice.authorizationStatus(for: .audio))
        },
        requestMicrophone: {
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            return granted
                ? .granted
                : mapAVAuthorization(AVCaptureDevice.authorizationStatus(for: .audio))
        },
        openMicrophoneSettings: {
            openSettings(pane: "Privacy_Microphone")
        },
        accessibilityTrusted: {
            AXIsProcessTrusted()
        },
        openAccessibilitySettings: {
            openSettings(pane: "Privacy_Accessibility")
        }
    )

    private static func mapAVAuthorization(_ status: AVAuthorizationStatus) -> PermissionStatus {
        switch status {
        case .notDetermined: return .notDetermined
        case .restricted, .denied: return .denied
        case .authorized: return .granted
        @unknown default: return .notDetermined
        }
    }

    // NSWorkspace.shared.open is @MainActor; the probe closures are @Sendable
    // and may be invoked from any actor. Hop to main with a fire-and-forget
    // Task — the user-visible action is "Settings opens", the caller doesn't
    // care about completion.
    private static func openSettings(pane: String) {
        let urlString = "x-apple.systempreferences:com.apple.preference.security?\(pane)"
        guard let url = URL(string: urlString) else { return }
        Task { @MainActor in
            _ = NSWorkspace.shared.open(url)
        }
    }
}
#endif
