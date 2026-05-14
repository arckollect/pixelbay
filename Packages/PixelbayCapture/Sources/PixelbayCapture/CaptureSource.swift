import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif
#if canImport(ScreenCaptureKit)
import ScreenCaptureKit
#endif
#if canImport(AVFoundation)
import AVFoundation
#endif

// What's being captured for the screen track.
//
// Only `.display` is wired into v0.1 UI; the other cases exist as plumbing so
// Phase 4 (area capture, iPhone / Continuity Camera) is an additive UI change
// rather than a CaptureSession rewrite.
//
// Each case stores the lightweight OS identifier (CGDirectDisplayID,
// CGWindowID, AVCaptureDevice.uniqueID) rather than the framework object
// itself — that keeps the type pure-data Sendable and round-trippable for
// logging / persistence. The live backend resolves identifiers back to the
// real SCDisplay / SCWindow / AVCaptureDevice at session-start time.
public enum CaptureSource: Sendable, Hashable {
    case display(displayID: CGDirectDisplayID)
    case window(windowID: CGWindowID)
    case area(rect: CGRect, displayID: CGDirectDisplayID)
    case device(deviceUniqueID: String)
}

#if canImport(ScreenCaptureKit)
extension CaptureSource {
    // Convenience inits for callers that already hold the SC types from
    // SCShareableContent. The init extracts the identifier only — the SC
    // object isn't retained here.
    public init(display: SCDisplay) {
        self = .display(displayID: display.displayID)
    }

    public init(window: SCWindow) {
        self = .window(windowID: window.windowID)
    }

    public init(area: CGRect, on display: SCDisplay) {
        self = .area(rect: area, displayID: display.displayID)
    }
}
#endif

#if canImport(AVFoundation)
extension CaptureSource {
    public init(device: AVCaptureDevice) {
        self = .device(deviceUniqueID: device.uniqueID)
    }
}
#endif
