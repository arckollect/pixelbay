import Foundation
#if canImport(AVFoundation)
import AVFoundation
#endif

#if canImport(AVFoundation)

// Sendable seam over AVCaptureDevice.DiscoverySession. Same Sendable-shim
// pattern as ShareableContentLookup / PermissionProbe; tests inject closures
// that return nil to exercise the `.sourceUnavailable` translation in
// LiveCaptureBackend.
public struct CaptureDeviceLookup: Sendable {
    public var camera: @Sendable (String) -> AVCaptureDevice?
    public var microphone: @Sendable (String) -> AVCaptureDevice?

    public init(
        camera: @escaping @Sendable (String) -> AVCaptureDevice?,
        microphone: @escaping @Sendable (String) -> AVCaptureDevice?
    ) {
        self.camera = camera
        self.microphone = microphone
    }

    public static let live = CaptureDeviceLookup(
        camera: { uniqueID in
            let session = AVCaptureDevice.DiscoverySession(
                deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera, .deskViewCamera],
                mediaType: .video,
                position: .unspecified
            )
            return session.devices.first { $0.uniqueID == uniqueID }
        },
        microphone: { uniqueID in
            let session = AVCaptureDevice.DiscoverySession(
                deviceTypes: [.microphone, .external],
                mediaType: .audio,
                position: .unspecified
            )
            return session.devices.first { $0.uniqueID == uniqueID }
        }
    )
}

#endif
