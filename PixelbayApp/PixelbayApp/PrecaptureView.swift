import AVFoundation
import AppKit
import CoreGraphics
import Foundation
import OSLog
import Observation
import PixelbayCapture
import PixelbayDesignSystem
import ScreenCaptureKit
import SwiftUI

private let log = Logger(subsystem: "com.pixelbay.PixelbayApp", category: "Precapture")

// §4.10's pre-capture picker. Replaces SmokeRecorderView's recording surface
// with a real source / camera / mic picker before the user clicks Record.
//
// Window capture, area capture, and Continuity Camera capture are deliberately
// not surfaced — LiveCaptureBackend translates them to .sourceUnavailable
// (Phase 4 territory). Only the Display picker is wired in v0.1.

@MainActor
@Observable
final class PrecaptureModel {
    struct DisplayChoice: Identifiable, Hashable {
        var id: CGDirectDisplayID
        var localizedName: String
        var width: Int
        var height: Int
        /// Display's bounds in **global points** (top-left origin in the
        /// same coordinate space `CGEvent.location` reports). Required for
        /// click-logger normalisation on multi-monitor setups — see
        /// `RecordingService.StartRequest.displayPointsBounds`.
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

    var selectedDisplayID: CGDirectDisplayID?
    var selectedCameraID: String?     // nil = "None"
    var selectedMicrophoneID: String? // nil = "None"
    var includeSystemAudio: Bool = true
    // Per-recording opt-in for the click logger (HANDOFF §6.7 + §4.7).
    // Default OFF — privacy-conscious, and Accessibility permission must
    // be granted for the underlying CGEventTap to fire. The toggle is
    // disabled in the picker UI when Accessibility isn't trusted.
    var logClicks: Bool = false

    var isLoading: Bool = false
    var loadError: String?

    func loadAvailableSources() async {
        isLoading = true
        loadError = nil
        defer { isLoading = false }
        do {
            let content = try await SCShareableContent.current
            displays = content.displays.map {
                DisplayChoice(
                    id: $0.displayID,
                    localizedName: displayName(for: $0),
                    width: $0.width,
                    height: $0.height,
                    globalBounds: $0.frame
                )
            }
            if selectedDisplayID == nil || !displays.contains(where: { $0.id == selectedDisplayID }) {
                selectedDisplayID = displays.first?.id
            }
        } catch {
            loadError = "Couldn't read shareable content: \(error.localizedDescription)"
            log.error("SCShareableContent load failed: \(String(describing: error), privacy: .public)")
            return
        }

        let cameraSession = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera, .deskViewCamera],
            mediaType: .video,
            position: .unspecified
        )
        cameras = cameraSession.devices.map {
            DeviceChoice(
                id: $0.uniqueID,
                localizedName: $0.localizedName,
                isVirtualLoopback: false
            )
        }
        if let prior = selectedCameraID, !cameras.contains(where: { $0.id == prior }) {
            selectedCameraID = nil
        }
        if selectedCameraID == nil {
            selectedCameraID = cameras.first(where: { !$0.isVirtualLoopback })?.id
        }

        let micSession = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external],
            mediaType: .audio,
            position: .unspecified
        )
        let virtualKeywords = ["BlackHole", "Loopback", "Soundflower", "VB-Cable", "Aggregate"]
        let allMics = micSession.devices.map { device -> DeviceChoice in
            let isVirtual = virtualKeywords.contains(where: { device.localizedName.contains($0) })
            return DeviceChoice(
                id: device.uniqueID,
                localizedName: device.localizedName,
                isVirtualLoopback: isVirtual
            )
        }
        // Physical devices first; virtual loopbacks pushed to the back so a
        // user-friendly default lands on the system mic, never BlackHole2ch
        // (which silently records 21s of zero-amplitude AAC — see HANDOFF
        // §3.16 iter 12 / 13).
        microphones = allMics.sorted { lhs, rhs in
            if lhs.isVirtualLoopback != rhs.isVirtualLoopback {
                return !lhs.isVirtualLoopback
            }
            return lhs.localizedName < rhs.localizedName
        }
        if let prior = selectedMicrophoneID, !microphones.contains(where: { $0.id == prior }) {
            selectedMicrophoneID = nil
        }
        if selectedMicrophoneID == nil {
            // Prefer the OS default input device per HANDOFF iter-13 lesson;
            // fall back to the first non-virtual entry.
            if let osDefault = AVCaptureDevice.default(for: .audio)?.uniqueID,
               microphones.contains(where: { $0.id == osDefault }) {
                selectedMicrophoneID = osDefault
            } else {
                selectedMicrophoneID = microphones.first(where: { !$0.isVirtualLoopback })?.id
            }
        }
    }

    var canRecord: Bool {
        selectedDisplayID != nil && !isLoading
    }

    func makeStartRequest() -> RecordingService.StartRequest? {
        guard let displayID = selectedDisplayID else { return nil }
        let picked = displays.first(where: { $0.id == displayID })
        return RecordingService.StartRequest(
            displayID: displayID,
            displayPointsBounds: picked?.globalBounds,
            cameraID: selectedCameraID,
            micID: selectedMicrophoneID,
            includeSystemAudio: includeSystemAudio,
            logClicks: logClicks
        )
    }

    private func displayName(for display: SCDisplay) -> String {
        // SCDisplay's CGDirectDisplayID maps back to NSScreen for a name.
        let screen = NSScreen.screens.first { screen in
            (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == display.displayID
        }
        let base = screen?.localizedName ?? "Display \(display.displayID)"
        let dims = "\(display.width) × \(display.height)"
        return "\(base) — \(dims)"
    }
}

struct PrecaptureView: View {
    @Bindable var model: PrecaptureModel
    /// True iff the user has granted the Accessibility permission. The
    /// click-logger Toggle is shown either way so users discover the
    /// feature, but it's disabled (with a "Grant in Settings" hint) when
    /// the permission isn't trusted — CGEventTap creation would fail.
    var accessibilityGranted: Bool
    /// Opens System Settings → Accessibility, surfaced when the user
    /// taps the toggle while permission isn't granted. Forwarded to
    /// PermissionViewModel.openSettings(for: .accessibility).
    var onRequestAccessibility: () -> Void
    var onRecord: () -> Void
    /// Opens an NSOpenPanel and routes the picked .pixelbay bundle into
    /// ContentView's ProjectDocument loader. Phase 2 entry point for
    /// editing prior recordings.
    var onOpenProject: () -> Void
    /// Phase 5 — opens the singleton Scene Recording window. The launcher
    /// stays on the picker so the user can switch between single-shot and
    /// multi-take recording without losing per-mode state.
    var onSceneRecording: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                Text("New Recording")
                    .font(Theme.Font.pageTitle)
                    .foregroundStyle(Theme.Color.textPrimary)
                Text("Pick the display, camera, and microphone to record. Pixelbay's own windows are excluded automatically.")
                    .font(Theme.Font.body)
                    .foregroundStyle(Theme.Color.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let loadError = model.loadError {
                HStack(alignment: .top, spacing: Theme.Spacing.sm) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.Color.warning)
                    Text(loadError).font(Theme.Font.body).foregroundStyle(Theme.Color.textPrimary)
                    Spacer()
                    Button("Retry") { Task { await model.loadAvailableSources() } }
                        .buttonStyle(.pbSecondary)
                }
                .padding(Theme.Spacing.md)
                .background(Theme.Color.warning.opacity(0.12), in: RoundedRectangle(cornerRadius: Theme.Radius.medium))
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.medium)
                        .strokeBorder(Theme.Color.warning.opacity(0.35), lineWidth: Theme.Stroke.hairline)
                )
            }

            sourceCard
            recordButton
            Spacer(minLength: 0)
        }
        .padding(40)
        .frame(minWidth: 620, minHeight: 460)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.Color.bgBase)
        .task { await model.loadAvailableSources() }
    }

    private var sourceCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            Picker("Display", selection: $model.selectedDisplayID) {
                if model.displays.isEmpty {
                    Text("No displays available").tag(CGDirectDisplayID?.none)
                }
                ForEach(model.displays) { display in
                    Text(display.localizedName).tag(CGDirectDisplayID?.some(display.id))
                }
            }
            .pickerStyle(.menu)

            Picker("Camera", selection: $model.selectedCameraID) {
                Text("None").tag(String?.none)
                ForEach(model.cameras) { cam in
                    Text(cam.localizedName).tag(String?.some(cam.id))
                }
            }
            .pickerStyle(.menu)

            Picker("Microphone", selection: $model.selectedMicrophoneID) {
                Text("None").tag(String?.none)
                ForEach(model.microphones) { mic in
                    Text(displayedMicLabel(mic)).tag(String?.some(mic.id))
                }
            }
            .pickerStyle(.menu)

            Toggle("Capture system audio", isOn: $model.includeSystemAudio)
            clickLogToggle
        }
        .tint(Theme.Color.accent)
        .pbCard(elevated: true)
    }

    @ViewBuilder
    private var clickLogToggle: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle("Log mouse clicks (for auto-zoom in Phase 3b)", isOn: $model.logClicks)
                .disabled(!accessibilityGranted)
            if !accessibilityGranted {
                HStack(spacing: Theme.Spacing.xs) {
                    Text("Requires Accessibility permission.")
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.Color.textSecondary)
                    Button("Grant in Settings…") {
                        onRequestAccessibility()
                    }
                    .buttonStyle(.link)
                    .font(Theme.Font.caption)
                }
            }
        }
    }

    @ViewBuilder
    private var recordButton: some View {
        HStack {
            Button(action: onRecord) {
                Label("Record", systemImage: "record.circle.fill")
                    .font(.title2.bold())
                    .padding(.vertical, 6)
                    .padding(.horizontal, 12)
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.Color.recordingRed)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .disabled(!model.canRecord)
            Button(action: onOpenProject) {
                Label("Open Project…", systemImage: "folder")
            }
            .controlSize(.large)
            .keyboardShortcut("o", modifiers: .command)
            Button(action: onSceneRecording) {
                Label("Scene-based Recording", systemImage: "rectangle.stack.badge.play")
            }
            .controlSize(.large)
            Spacer()
            if model.isLoading {
                HStack(spacing: Theme.Spacing.xs) {
                    ProgressView().controlSize(.small)
                    Text("Loading sources…")
                        .font(Theme.Font.body)
                        .foregroundStyle(Theme.Color.textSecondary)
                }
            }
        }
    }

    private func displayedMicLabel(_ mic: PrecaptureModel.DeviceChoice) -> String {
        if mic.isVirtualLoopback {
            return "\(mic.localizedName) (virtual loopback — typically silent)"
        }
        return mic.localizedName
    }
}

#Preview {
    PrecaptureView(
        model: PrecaptureModel(),
        accessibilityGranted: false,
        onRequestAccessibility: {},
        onRecord: {},
        onOpenProject: {},
        onSceneRecording: {}
    )
}
