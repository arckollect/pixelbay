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

/// UserDefaults key backing `PrecaptureModel.logClicks` so the choice
/// survives across recordings and app launches (the picker model is a fresh
/// instance each session otherwise, which used to reset the toggle to OFF
/// every time).
private let logClicksDefaultsKey = "precapture.logClicks"

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
    // Cursor logging (HANDOFF §6.7 + §4.7). The CGEventTap behind this
    // captures BOTH the continuous mouse trajectory — which powers zoom
    // cursor-follow — AND discrete clicks/gestures, which power auto-zoom.
    // Default ON and persisted (see `logClicksDefaultsKey`) so cursor-follow
    // "just works" out of the box, matching the Scenes recording path
    // (`ScenesSession.logClicks` already defaults true). Still gated by
    // Accessibility: the picker disables the toggle when the permission isn't
    // trusted, and RecordingService skips the sidecar gracefully if the tap
    // can't arm — so a true value here is harmless without permission.
    var logClicks: Bool = UserDefaults.standard.object(forKey: logClicksDefaultsKey) as? Bool ?? true {
        didSet { UserDefaults.standard.set(logClicks, forKey: logClicksDefaultsKey) }
    }

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
    // Hosting window + drag anchor, so we can move the floating bar ourselves
    // (see `windowDrag`) instead of relying on AppKit's background drag, which
    // breaks the Liquid Glass backdrop mid-drag.
    @State private var hostWindow: NSWindow?
    @State private var dragAnchor: (window: CGPoint, mouse: CGPoint)?
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
    /// Closes the floating bar (dismisses the launcher window). The menubar
    /// status item's "Show Pixelbay" brings it back.
    var onClose: () -> Void = {}

    // Screen-Studio-style floating hover bar. The launcher window is restyled
    // (borderless, floating, bottom-centred) by `LauncherWindowChrome` while
    // this view is on screen; here we just render the bar itself with a
    // transparent margin so the drop shadow has room.
    var body: some View {
        HStack(spacing: Theme.Spacing.sm) {
            closeButton
            barDivider
            sourceSegment
            barDivider
            cameraControl
            micControl
            systemAudioControl
            barDivider
            sceneButton
            recordButton
            barDivider
            overflowMenu
        }
        .padding(.horizontal, Theme.Spacing.md)
        .padding(.vertical, Theme.Spacing.sm)
        .frame(height: 64)
        // Liquid Glass (macOS 26): a translucent, dark-tinted glass panel —
        // not a flat fill — so the desktop reads faintly through it. The
        // bar window is borderless + clear (LauncherWindowChrome), so the
        // material has real backdrop to refract. Falls back to a frosted
        // material on pre-26 systems (deployment target is 14.6).
        .pbGlassBar(barShape)
        .overlay(
            barShape.strokeBorder(Color.white.opacity(0.12), lineWidth: Theme.Stroke.regular)
        )
        // No drop shadow: any shadow renders as a faded grey backdrop box
        // around the bar on light desktops, which reads as unwanted chrome.
        // The white hairline stroke above provides the edge separation the
        // bar needs — we want only the toolbar visible.
        .padding(Theme.Spacing.xl)          // transparent margin keeps layout stable
        .fixedSize()                         // window sizes to the bar (contentSize)
        .tint(.white)                        // white menu labels — no orange accent
        // WindowAccessor (shared helper, ProjectWindow.swift) invokes this
        // inside SwiftUI's view-update pass, so assigning the @State window
        // synchronously trips "Modifying state during view update". Skip
        // no-op deliveries and defer the real assignment past the current pass.
        .background(WindowAccessor { window in
            guard hostWindow !== window else { return }
            DispatchQueue.main.async { hostWindow = window }
        })
        .gesture(windowDrag)
        .task { await model.loadAvailableSources() }
    }

    /// Moves the floating bar window by following the absolute mouse position
    /// on screen. We anchor to the window origin + mouse location at drag start
    /// and apply the delta, so the window can't chase the pointer into a
    /// feedback loop. Runs on the normal runloop (unlike AppKit's blocking
    /// background drag), keeping the Liquid Glass backdrop live throughout.
    private var windowDrag: some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { _ in
                guard let window = hostWindow else { return }
                let mouse = NSEvent.mouseLocation        // global, bottom-left origin
                let anchor = dragAnchor ?? (window.frame.origin, mouse)
                if dragAnchor == nil { dragAnchor = anchor }
                window.setFrameOrigin(
                    NSPoint(
                        x: anchor.window.x + (mouse.x - anchor.mouse.x),
                        y: anchor.window.y + (mouse.y - anchor.mouse.y)
                    )
                )
            }
            .onEnded { _ in dragAnchor = nil }
    }

    // MARK: - Bar pieces

    private var barShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: Theme.Radius.large, style: .continuous)
    }

    private var barDivider: some View {
        PBDivider(.vertical).frame(height: 34)
    }

    private var closeButton: some View {
        Button(action: onClose) {
            Image(systemName: "xmark")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(Theme.Color.bgElevated)
                .frame(width: 28, height: 28)
                .background(Circle().fill(Theme.Color.textPrimary))
        }
        .buttonStyle(.plain)
        .help("Close — reopen from the menu bar")
    }

    // Source-type segment. Only Display records today; Window / Area / Device
    // are Phase-4 deferred so they render dimmed + non-interactive with a
    // "coming soon" tooltip (matches the Screen Studio layout).
    private var sourceSegment: some View {
        HStack(spacing: Theme.Spacing.xs) {
            Menu {
                if model.displays.isEmpty {
                    Text("No displays available")
                }
                ForEach(model.displays) { display in
                    Button {
                        model.selectedDisplayID = display.id
                    } label: {
                        sourceMenuItem(display.localizedName, checked: display.id == model.selectedDisplayID)
                    }
                }
            } label: {
                sourceTile(icon: "display", title: "Display", selected: true, enabled: true)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Choose which display to record")

            sourceTile(icon: "macwindow", title: "Window", selected: false, enabled: false)
                .help("Window capture — coming soon")
            sourceTile(icon: "rectangle.dashed", title: "Area", selected: false, enabled: false)
                .help("Area capture — coming soon")
            sourceTile(icon: "iphone", title: "Device", selected: false, enabled: false)
                .help("Device capture — coming soon")
        }
    }

    private func sourceTile(icon: String, title: String, selected: Bool, enabled: Bool) -> some View {
        VStack(spacing: 3) {
            Image(systemName: icon).font(.system(size: 17, weight: .regular))
            Text(title).font(Theme.Font.caption)
        }
        .foregroundStyle(selected ? Theme.Color.textPrimary : (enabled ? Theme.Color.textPrimary : Theme.Color.textTertiary))
        .frame(width: 58, height: 46)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.small)
                .fill(selected ? Color.white.opacity(0.14) : Color.clear)
        )
        .opacity(enabled ? 1 : 0.5)
    }

    private var cameraControl: some View {
        Menu {
            Button { model.selectedCameraID = nil } label: {
                sourceMenuItem("None", checked: model.selectedCameraID == nil)
            }
            ForEach(model.cameras) { cam in
                Button { model.selectedCameraID = cam.id } label: {
                    sourceMenuItem(cam.localizedName, checked: cam.id == model.selectedCameraID)
                }
            }
        } label: {
            inlineControl(
                icon: model.selectedCameraID == nil ? "video.slash.fill" : "video.fill",
                title: cameraTitle,
                color: model.selectedCameraID == nil ? Theme.Color.textSecondary : Theme.Color.textPrimary
            )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private var micControl: some View {
        Menu {
            Button { model.selectedMicrophoneID = nil } label: {
                sourceMenuItem("None", checked: model.selectedMicrophoneID == nil)
            }
            ForEach(model.microphones) { mic in
                Button { model.selectedMicrophoneID = mic.id } label: {
                    sourceMenuItem(displayedMicLabel(mic), checked: mic.id == model.selectedMicrophoneID)
                }
            }
        } label: {
            inlineControl(
                icon: model.selectedMicrophoneID == nil ? "mic.slash.fill" : "mic.fill",
                title: micTitle,
                color: model.selectedMicrophoneID == nil ? Theme.Color.textSecondary : Theme.Color.textPrimary
            )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private var systemAudioControl: some View {
        Button {
            model.includeSystemAudio.toggle()
        } label: {
            inlineControl(
                icon: model.includeSystemAudio ? "speaker.wave.2.fill" : "speaker.slash.fill",
                title: "System audio",
                color: model.includeSystemAudio ? Theme.Color.textPrimary : Theme.Color.textSecondary
            )
        }
        .buttonStyle(.plain)
        .help(model.includeSystemAudio ? "System audio will be recorded" : "System audio is off")
    }

    private var sceneButton: some View {
        Button(action: onSceneRecording) {
            inlineControl(icon: "rectangle.stack.badge.play", title: "Scenes", color: Theme.Color.textPrimary)
        }
        .buttonStyle(.plain)
        .help("Scene-based recording — record takes and merge")
    }

    private var recordButton: some View {
        Button(action: onRecord) {
            HStack(spacing: Theme.Spacing.xs) {
                Image(systemName: "record.circle.fill")
                Text("Record").font(Theme.Font.bodyEmphasized)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, Theme.Spacing.lg)
            .frame(height: 40)
            .background(Capsule().fill(Theme.Color.recordingRed))
            .opacity(model.canRecord ? 1 : 0.45)
        }
        .buttonStyle(.plain)
        .disabled(!model.canRecord)
        .keyboardShortcut(.defaultAction)
        .help(model.canRecord ? "Start recording" : "Pick a display first")
    }

    private var overflowMenu: some View {
        Menu {
            Toggle("Track cursor (zoom follow + auto-zoom)", isOn: $model.logClicks)
                .disabled(!accessibilityGranted)
            if !accessibilityGranted {
                Button("Grant Accessibility…") { onRequestAccessibility() }
            }
            Divider()
            Button("Open Project…") { onOpenProject() }
                .keyboardShortcut("o", modifiers: .command)
        } label: {
            HStack(spacing: 2) {
                Image(systemName: "gearshape.fill").font(.system(size: 14))
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
            }
            .foregroundStyle(Theme.Color.textSecondary)
            .frame(height: 44)
            .padding(.horizontal, Theme.Spacing.xs)
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    // MARK: - Shared label builders

    private func inlineControl(icon: String, title: String, color: Color) -> some View {
        HStack(spacing: Theme.Spacing.xs) {
            Image(systemName: icon).font(.system(size: 14))
            Text(title)
                .font(Theme.Font.bodyEmphasized)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .foregroundStyle(color)
        .padding(.horizontal, Theme.Spacing.sm)
        .frame(height: 44)
        .frame(maxWidth: 160)
        .contentShape(Rectangle())
    }

    private func sourceMenuItem(_ text: String, checked: Bool) -> some View {
        HStack {
            if checked { Image(systemName: "checkmark") }
            Text(text)
        }
    }

    private var cameraTitle: String {
        guard let id = model.selectedCameraID,
              let cam = model.cameras.first(where: { $0.id == id }) else { return "No camera" }
        return cam.localizedName
    }

    private var micTitle: String {
        guard let id = model.selectedMicrophoneID,
              let mic = model.microphones.first(where: { $0.id == id }) else { return "No microphone" }
        return mic.localizedName
    }

    private func displayedMicLabel(_ mic: PrecaptureModel.DeviceChoice) -> String {
        if mic.isVirtualLoopback {
            return "\(mic.localizedName) (virtual loopback — typically silent)"
        }
        return mic.localizedName
    }
}

// Frosted dark-glass bar background, clipped to the bar shape.
//
// Glass recipe promoted to `View.pbGlassBar(_:)` in PixelbayDesignSystem.

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
