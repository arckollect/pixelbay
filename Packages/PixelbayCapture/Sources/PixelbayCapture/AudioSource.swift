import Foundation
#if canImport(AVFoundation)
import AVFoundation
#endif

// Microphone selection for a capture session. `.builtIn` and `.external`
// look the same to the recording pipeline today; the distinction is here so
// Phase 4's "Audio device picker" UI can group sources without revisiting the
// schema. Stored as the device's unique ID for the same Sendable-friendliness
// reason as CaptureSource.
public enum AudioSource: Sendable, Hashable {
    case none
    case builtIn(deviceUniqueID: String)
    case external(deviceUniqueID: String)

    public var deviceUniqueID: String? {
        switch self {
        case .none: return nil
        case .builtIn(let id), .external(let id): return id
        }
    }
}

#if canImport(AVFoundation)
extension AudioSource {
    // Convenience init from an AVCaptureDevice. Defaults to `.external`
    // because macOS 14 deprecated the `.builtInMicrophone` deviceType in
    // favour of a generic `.microphone`, leaving no first-class discriminator
    // for built-in vs external. Callers that know they're picking the system
    // default mic can override with `.builtIn(deviceUniqueID:)` directly.
    public init(device: AVCaptureDevice) {
        self = .external(deviceUniqueID: device.uniqueID)
    }
}
#endif
