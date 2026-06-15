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
private let selectedCameraDefaultsKey = "precapture.selectedCameraID"

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
    var selectedCameraID: String? = UserDefaults.standard.string(forKey: selectedCameraDefaultsKey) {
        didSet {
            if let selectedCameraID {
                UserDefaults.standard.set(selectedCameraID, forKey: selectedCameraDefaultsKey)
            } else {
                UserDefaults.standard.removeObject(forKey: selectedCameraDefaultsKey)
            }
        }
    }
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
    @State private var hoveredControl: ToolbarControl?
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

    private enum ToolbarControl: Hashable {
        case source, camera, mic, systemAudio, scenes, close, record, overflow
    }

    // Screen-Studio-style floating hover bar. The launcher window is restyled
    // (borderless, floating, bottom-centred) by `LauncherWindowChrome` while
    // this view is on screen; here we just render the bar itself with a
    // transparent margin so the drop shadow has room.
    var body: some View {
        HStack(spacing: Theme.Spacing.md) {
            closeButton
            barDivider
            sourceControl
            barDivider
            cameraControl
            micControl
            systemAudioControl
            barDivider
            scenesButton
            recordButton
            barDivider
            overflowMenu
        }
        .padding(.horizontal, Theme.Spacing.sm)
        .padding(.vertical, Theme.Spacing.sm)
        .frame(height: 68)
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
        PBDivider(.vertical).frame(height: 36)
    }

    private var closeButton: some View {
        Button(action: onClose) {
            Image(systemName: "xmark")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(Theme.Color.bgElevated)
                .frame(width: 28, height: 28)
                .background(Circle().fill(Theme.Color.textPrimary))
                .scaleEffect(hoveredControl == .close ? 1.08 : 1)
                .animation(.easeOut(duration: 0.14), value: hoveredControl == .close)
                .onHover { setHovered(.close, $0) }
        }
        .buttonStyle(.plain)
        .help("Close — reopen from the menu bar")
    }

    // The three pickers are `Button`s that pop a native `NSMenu`, NOT SwiftUI
    // `Menu`s. A `.borderlessButton` Menu is backed by an AppKit pop-up control
    // that swallows SwiftUI hover tracking across its whole area, so no hover
    // highlight ever appeared (only the plain-Button systemAudio control did).
    // A real Button gets `.onHover`, and `NSMenu.popUp` reproduces the dropdown.
    private var sourceControl: some View {
        BarMenuControl(width: 132, makeMenu: makeSourceMenu, onHoverChange: { setHovered(.source, $0) }) {
            inlineControl(
                icon: "display",
                title: sourceTitle,
                color: model.selectedDisplayID == nil ? Theme.Color.textSecondary : Theme.Color.textPrimary,
                width: 132,
                isHovered: hoveredControl == .source
            )
        }
        .help(sourceHelp)
    }

    private var cameraControl: some View {
        BarMenuControl(width: 110, makeMenu: makeCameraMenu, onHoverChange: { setHovered(.camera, $0) }) {
            inlineControl(
                icon: model.selectedCameraID == nil ? "video.slash.fill" : "video.fill",
                title: cameraTitle,
                color: model.selectedCameraID == nil ? Theme.Color.textSecondary : Theme.Color.textPrimary,
                width: 110,
                isHovered: hoveredControl == .camera
            )
        }
        .help(cameraHelp)
    }

    private var micControl: some View {
        BarMenuControl(width: 118, makeMenu: makeMicMenu, onHoverChange: { setHovered(.mic, $0) }) {
            inlineControl(
                icon: model.selectedMicrophoneID == nil ? "mic.slash.fill" : "mic.fill",
                title: micTitle,
                color: model.selectedMicrophoneID == nil ? Theme.Color.textSecondary : Theme.Color.textPrimary,
                width: 118,
                isHovered: hoveredControl == .mic
            )
        }
        .help(micHelp)
    }

    // MARK: - NSMenu builders (popped by `BarMenuControl`)

    private func makeSourceMenu() -> NSMenu {
        let menu = NSMenu()
        if model.displays.isEmpty {
            menu.addItem(disabledItem("No displays available"))
        }
        for display in model.displays {
            menu.addItem(menuItem(display.localizedName, checked: display.id == model.selectedDisplayID) {
                model.selectedDisplayID = display.id
            })
        }
        menu.addItem(.separator())
        for title in ["Window capture — Coming soon", "Area capture — Coming soon", "Device capture — Coming soon"] {
            menu.addItem(disabledItem(title))
        }
        return menu
    }

    private func makeCameraMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(menuItem("Camera off", checked: model.selectedCameraID == nil) {
            model.selectedCameraID = nil
        })
        for cam in model.cameras {
            menu.addItem(menuItem(cam.localizedName, checked: cam.id == model.selectedCameraID) {
                model.selectedCameraID = cam.id
            })
        }
        return menu
    }

    private func makeMicMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(menuItem("Mic off", checked: model.selectedMicrophoneID == nil) {
            model.selectedMicrophoneID = nil
        })
        for mic in model.microphones {
            menu.addItem(menuItem(displayedMicLabel(mic), checked: mic.id == model.selectedMicrophoneID) {
                model.selectedMicrophoneID = mic.id
            })
        }
        return menu
    }

    private func menuItem(_ title: String, checked: Bool, enabled: Bool = true, _ action: @escaping () -> Void) -> NSMenuItem {
        let item = ClosureMenuItem(title: title, action: #selector(ClosureMenuItem.fire), keyEquivalent: "")
        item.target = item
        item.onSelect = action
        item.state = checked ? .on : .off
        item.isEnabled = enabled
        return item
    }

    private func disabledItem(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private var systemAudioControl: some View {
        Button {
            model.includeSystemAudio.toggle()
        } label: {
            inlineControl(
                icon: model.includeSystemAudio ? "speaker.wave.2.fill" : "speaker.slash.fill",
                title: model.includeSystemAudio ? "System audio" : "System off",
                color: model.includeSystemAudio ? Theme.Color.textPrimary : Theme.Color.textSecondary,
                width: 136,
                isHovered: hoveredControl == .systemAudio
            )
            .onHover { setHovered(.systemAudio, $0) }
        }
        .buttonStyle(.plain)
        .help(model.includeSystemAudio ? "System audio will be recorded" : "System audio is off")
    }

    // Direct entry to the multi-take Scenes panel — surfaced on the bar so it's
    // one click away rather than buried in the overflow menu. A plain action
    // button (not a mode toggle): one click opens the panel.
    private var scenesButton: some View {
        Button(action: onSceneRecording) {
            Image(systemName: "rectangle.stack.badge.play.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(hoveredControl == .scenes ? Theme.Color.textPrimary : Theme.Color.textSecondary)
                .frame(width: 40, height: 44)
                .background(
                    RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous)
                        .fill(Color.white.opacity(hoveredControl == .scenes ? 0.13 : 0.001))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous)
                        .strokeBorder(Color.white.opacity(hoveredControl == .scenes ? 0.18 : 0),
                                      lineWidth: Theme.Stroke.hairline)
                )
                .scaleEffect(hoveredControl == .scenes ? 1.05 : 1)
                .animation(.easeOut(duration: 0.14), value: hoveredControl == .scenes)
                .onHover { setHovered(.scenes, $0) }
        }
        .buttonStyle(.plain)
        .help("Scene recording — capture multiple takes")
    }

    private var recordButton: some View {
        Button(action: onRecord) {
            HStack(spacing: Theme.Spacing.xs) {
                Image(systemName: "record.circle.fill")
                Text("Record").font(Theme.Font.bodyEmphasized)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, Theme.Spacing.sm)
            .frame(width: 100, height: 44)
            .background(Capsule().fill(Theme.Color.recordingRed))
            .opacity(model.canRecord ? 1 : 0.45)
            .scaleEffect(hoveredControl == .record ? 1.03 : 1)
            .brightness(hoveredControl == .record ? 0.06 : 0)
            .animation(.easeOut(duration: 0.14), value: hoveredControl == .record)
            .onHover { setHovered(.record, $0 && model.canRecord) }
        }
        .buttonStyle(.plain)
        .disabled(!model.canRecord)
        .keyboardShortcut(.defaultAction)
        .help(model.canRecord ? "Start recording" : "Pick a display first")
    }

    private var overflowMenu: some View {
        BarMenuControl(width: 34, makeMenu: makeOverflowMenu, onHoverChange: { setHovered(.overflow, $0) }) {
            Image(systemName: "gearshape.fill")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(hoveredControl == .overflow ? Theme.Color.textPrimary : Theme.Color.textSecondary)
                .frame(width: 34, height: 44)
                .background(
                    Circle()
                        .fill(Color.white.opacity(hoveredControl == .overflow ? 0.13 : 0))
                        .frame(width: 32, height: 32)
                )
                .scaleEffect(hoveredControl == .overflow ? 1.05 : 1)
                .animation(.easeOut(duration: 0.14), value: hoveredControl == .overflow)
        }
        .help("More options")
    }

    private func makeOverflowMenu() -> NSMenu {
        // Scene Recording moved out to the `scenesButton` bar button.
        let menu = NSMenu()
        menu.autoenablesItems = false   // respect our explicit isEnabled (disabled toggle)
        menu.addItem(menuItem("Track cursor (zoom follow + auto-zoom)",
                              checked: model.logClicks,
                              enabled: accessibilityGranted) {
            model.logClicks.toggle()
        })
        if !accessibilityGranted {
            menu.addItem(menuItem("Grant Accessibility…", checked: false) { onRequestAccessibility() })
        }
        menu.addItem(.separator())
        let open = menuItem("Open Project…", checked: false) { onOpenProject() }
        open.keyEquivalent = "o"
        open.keyEquivalentModifierMask = .command
        menu.addItem(open)
        return menu
    }

    // MARK: - Shared label builders

    private func setHovered(_ control: ToolbarControl, _ isHovered: Bool) {
        if isHovered {
            hoveredControl = control
        } else if hoveredControl == control {
            hoveredControl = nil
        }
    }

    private func inlineControl(icon: String, title: String, color: Color, width: CGFloat, isHovered: Bool) -> some View {
        let horizontalPadding = Theme.Spacing.sm
        let iconWidth: CGFloat = 16
        let textWidth = max(28, width - (horizontalPadding * 2) - iconWidth - Theme.Spacing.xs)
        return HStack(spacing: Theme.Spacing.xs) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .frame(width: iconWidth)
            Text(title)
                .font(Theme.Font.bodyEmphasized)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: textWidth, alignment: .leading)
        }
        .foregroundStyle(color)
        .padding(.horizontal, horizontalPadding)
        .frame(width: width, height: 44, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous)
                .fill(Color.white.opacity(isHovered ? 0.13 : 0.001))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous)
                .strokeBorder(Color.white.opacity(isHovered ? 0.18 : 0), lineWidth: Theme.Stroke.hairline)
        )
        .scaleEffect(isHovered ? 1.025 : 1)
        .animation(.easeOut(duration: 0.14), value: isHovered)
        .clipped()
        .contentShape(Rectangle())
    }

    private var sourceTitle: String {
        guard let id = model.selectedDisplayID,
              let display = model.displays.first(where: { $0.id == id }) else {
            return model.isLoading ? "Loading display" : "No display"
        }
        return display.localizedName
    }

    private var sourceHelp: String {
        model.selectedDisplayID == nil ? "Choose which display to record" : "Recording \(sourceTitle)"
    }

    private var cameraTitle: String {
        guard let id = model.selectedCameraID,
              let cam = model.cameras.first(where: { $0.id == id }) else { return "Camera off" }
        return cam.localizedName
    }

    private var cameraHelp: String {
        model.selectedCameraID == nil ? "Camera is off" : "Camera: \(cameraTitle)"
    }

    private var micTitle: String {
        guard let id = model.selectedMicrophoneID,
              let mic = model.microphones.first(where: { $0.id == id }) else { return "Mic off" }
        return mic.localizedName
    }

    private var micHelp: String {
        model.selectedMicrophoneID == nil ? "Microphone is off" : "Microphone: \(micTitle)"
    }

    private func displayedMicLabel(_ mic: PrecaptureModel.DeviceChoice) -> String {
        if mic.isVirtualLoopback {
            return "\(mic.localizedName) (virtual loopback — typically silent)"
        }
        return mic.localizedName
    }
}

/// A toolbar picker rendered as a real `Button` so SwiftUI `.onHover` fires.
/// (It replaces a `.borderlessButton` SwiftUI `Menu`, whose AppKit pop-up
/// backing swallowed hover tracking across its whole area — which is why the
/// menu controls never highlighted while the plain-Button systemAudio one did.)
/// Clicking pops a native `NSMenu` anchored beneath the control.
private struct BarMenuControl<Label: View>: View {
    let width: CGFloat
    let makeMenu: () -> NSMenu
    let onHoverChange: (Bool) -> Void
    @ViewBuilder var label: () -> Label

    @State private var anchor = MenuAnchor()

    var body: some View {
        Button {
            anchor.present(makeMenu())
        } label: {
            label()
        }
        .buttonStyle(.plain)
        .frame(width: width, height: 44)
        .contentShape(Rectangle())
        .onHover(perform: onHoverChange)
        .background(MenuAnchorView(anchor: anchor))
    }
}

/// Holds the control's backing NSView so the popped `NSMenu` can anchor to it.
@MainActor private final class MenuAnchor {
    weak var view: NSView?

    func present(_ menu: NSMenu) {
        guard let view else { return }
        // Anchor at the control's top-left; near the screen bottom AppKit
        // auto-flips the menu upward so it never opens off-screen.
        menu.popUp(positioning: nil,
                   at: NSPoint(x: 0, y: view.bounds.height + 6),
                   in: view)
    }
}

private struct MenuAnchorView: NSViewRepresentable {
    let anchor: MenuAnchor

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        anchor.view = view
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        anchor.view = nsView
    }

    // Fill the control's frame so the menu anchors to the full control rect
    // (a bare NSView has no intrinsic size and would otherwise collapse).
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSView, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions()
    }
}

/// `NSMenuItem` that runs a closure when chosen, so menus can be built inline
/// from the SwiftUI model without wiring a separate @objc target per item.
private final class ClosureMenuItem: NSMenuItem {
    var onSelect: (() -> Void)?
    @objc func fire() { onSelect?() }
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
