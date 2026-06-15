import AVFoundation
import AppKit
import CoreGraphics
import Foundation
import OSLog
import Observation
import ScreenCaptureKit

private let log = Logger(subsystem: "com.pixelbay.PixelbayApp", category: "ScenesSourceCatalog")

// Phase 5 — source enumeration for the Scenes window. Mirrors
// `PrecaptureModel.loadAvailableSources`'s shape but writes into a catalog
// the scenes window's defaults & per-scene overrides bind against. Kept
// separate from PrecaptureModel because the scenes window has no notion
// of canRecord / makeStartRequest — that's RecordingService's job once a
// scene row's Record button fires.

@MainActor
@Observable
final class ScenesSourceCatalog {

    struct DisplayChoice: Identifiable, Hashable {
        var id: CGDirectDisplayID
        var localizedName: String
        var width: Int
        var height: Int
        var globalBounds: CGRect
    }

    struct DeviceChoice: Identifiable, Hashable {
        var id: String   // AVCaptureDevice.uniqueID
        var localizedName: String
        var isVirtualLoopback: Bool
    }

    var displays: [DisplayChoice] = []
    var cameras: [DeviceChoice] = []
    var microphones: [DeviceChoice] = []
    var isLoading: Bool = false
    var loadError: String?

    func reload() async {
        isLoading = true
        loadError = nil
        defer { isLoading = false }
        do {
            let content = try await SCShareableContent.current
            displays = content.displays.map {
                DisplayChoice(
                    id: $0.displayID,
                    localizedName: Self.displayName(for: $0),
                    width: $0.width,
                    height: $0.height,
                    globalBounds: $0.frame
                )
            }
        } catch {
            loadError = "Couldn't read shareable content: \(error.localizedDescription)"
            log.error("SCShareableContent load failed: \(String(describing: error), privacy: .public)")
        }

        let cameraSession = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera, .deskViewCamera],
            mediaType: .video,
            position: .unspecified
        )
        cameras = cameraSession.devices.map {
            DeviceChoice(id: $0.uniqueID, localizedName: $0.localizedName, isVirtualLoopback: false)
        }

        let micSession = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external],
            mediaType: .audio,
            position: .unspecified
        )
        // Same virtual-loopback filter as PrecaptureModel — keeps BlackHole
        // et al. visible but pushed to the back, so the default mic landing
        // doesn't silently produce 21s of zero-amplitude AAC.
        let virtualKeywords = ["BlackHole", "Loopback", "Soundflower", "VB-Cable", "Aggregate"]
        let allMics = micSession.devices.map { device -> DeviceChoice in
            let isVirtual = virtualKeywords.contains(where: { device.localizedName.contains($0) })
            return DeviceChoice(
                id: device.uniqueID,
                localizedName: device.localizedName,
                isVirtualLoopback: isVirtual
            )
        }
        microphones = allMics.sorted { lhs, rhs in
            if lhs.isVirtualLoopback != rhs.isVirtualLoopback {
                return !lhs.isVirtualLoopback
            }
            return lhs.localizedName < rhs.localizedName
        }
    }

    /// Defaults sensible at first load — same OS-default-mic strategy as
    /// PrecaptureModel, plus the primary display. Camera is intentionally
    /// privacy-first: keep a valid existing camera, but never auto-select a
    /// replacement when the field is missing or stale.
    func seedingDefaultsIfMissing(
        from existing: (displayID: UInt32?, cameraUniqueID: String?, micUniqueID: String?)
    ) -> (displayID: UInt32?, cameraUniqueID: String?, micUniqueID: String?) {
        var displayID = existing.displayID
        if displayID == nil || !displays.contains(where: { $0.id == displayID }) {
            displayID = displays.first?.id
        }
        var cameraUniqueID = existing.cameraUniqueID
        if let prior = cameraUniqueID, !cameras.contains(where: { $0.id == prior }) {
            cameraUniqueID = nil
        }
        var micUniqueID = existing.micUniqueID
        if let prior = micUniqueID, !microphones.contains(where: { $0.id == prior }) {
            micUniqueID = nil
        }
        if micUniqueID == nil {
            if let osDefault = AVCaptureDevice.default(for: .audio)?.uniqueID,
               microphones.contains(where: { $0.id == osDefault })
            {
                micUniqueID = osDefault
            } else {
                micUniqueID = microphones.first(where: { !$0.isVirtualLoopback })?.id
            }
        }
        return (displayID, cameraUniqueID, micUniqueID)
    }

    static func displayName(for display: SCDisplay) -> String {
        let screen = NSScreen.screens.first { screen in
            (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == display.displayID
        }
        let base = screen?.localizedName ?? "Display \(display.displayID)"
        let dims = "\(display.width) × \(display.height)"
        return "\(base) — \(dims)"
    }
}
