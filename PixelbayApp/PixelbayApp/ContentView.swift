import AppKit
import OSLog
import PixelbayDesignSystem
import PixelbayPermissions
import SwiftUI
import UniformTypeIdentifiers

private let contentLog = Logger(subsystem: "com.pixelbay.PixelbayApp", category: "ContentView")

// Launcher window content. Routes:
//   permissions not yet satisfied → OnboardingView
//   required permissions granted   → PrecaptureView (or PostCaptureView once
//                                    a recording finishes; New Recording
//                                    flips back to PrecaptureView).
//
// Project editing is its own window (WindowGroup("Project", for:
// ProjectWindowID.self)). Opening a project — from the post-capture
// "Edit Project" button or File > Open Project… — calls openWindow(value:)
// to spawn an editor in a separate NSWindow. This view never embeds
// ProjectView itself; the launcher stays focused on capture.
//
// The recording HUD is a separate floating panel managed by PixelbayAppApp;
// it's not part of this view's tree because it has to outlive any single
// SwiftUI window.

struct ContentView: View {
    @State private var permissions = PermissionViewModel(
        coordinator: PermissionCoordinator(probe: .live)
    )
    @State private var dismissedOnboarding = false
    @Environment(RecordingService.self) private var recording
    @Environment(ScenesAppendTarget.self) private var scenesAppendTarget
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var precaptureModel = PrecaptureModel()
    @State private var orphans = OrphanRecoveryModel()

    var body: some View {
        Group {
            if dismissedOnboarding && permissions.requiredSatisfied {
                postOnboardingScene
            } else {
                OnboardingView(viewModel: permissions) {
                    dismissedOnboarding = true
                }
            }
        }
        .background(LauncherWindowChrome(isBar: isPickerRoute, isOnboarding: isOnboardingRoute))
        // Intercept the launcher window's ✕ during post-capture so closing the
        // review discards the take and returns to the picker (see
        // LauncherCloseInterceptor), rather than silently closing the window
        // and stranding the user with no record bar.
        .background(WindowAccessor { window in
            installLauncherCloseInterceptor(on: window)
        })
        .task {
            // Teach orphan recovery which bundle is live so it never flags or
            // discards the active recording (its in-progress marker otherwise
            // reads as an interrupted recording). Lazily queried at scan time.
            orphans.activeBundleURLs = { [weak recording] in recording?.activeBundleURLs ?? [] }
            orphans.scan()
        }
        .onReceive(NotificationCenter.default.publisher(for: .pixelbayNewRecordingRequested)) { _ in
            // ⌘N (or "New Recording" menu item) clears any post-capture
            // state so the launcher lands on the picker. The launcher
            // window has already been brought forward by openWindow(id:).
            recording.acknowledgeResult()
        }
        .sheet(isPresented: Binding(
            get: { orphans.isPresented },
            set: { newValue in if !newValue { orphans.dismiss() } }
        )) {
            OrphanRecoverySheet(model: orphans)
        }
    }

    /// True while the onboarding scene is showing — drives the edge-to-edge
    /// transparent-titlebar window chrome so the dark surface reaches the top.
    private var isOnboardingRoute: Bool {
        !(dismissedOnboarding && permissions.requiredSatisfied)
    }

    /// True when the launcher is showing the New Recording picker — the only
    /// route that renders as the floating hover bar. Onboarding, the
    /// recording placeholder, and post-capture keep normal window chrome.
    private var isPickerRoute: Bool {
        guard dismissedOnboarding, permissions.requiredSatisfied else { return false }
        switch recording.phase {
        case .recording, .stopping, .stopped: return false
        default: return true
        }
    }

    /// Opens a `.pixelbay` bundle in its own editor window via the
    /// WindowGroup(for: ProjectWindowID.self) scene. Called from
    /// PostCaptureView's "Edit Project" button and from PrecaptureView's
    /// "Open Project…" button.
    private func openProjectBundle(at url: URL) {
        openWindow(value: ProjectWindowID(bundleURL: url))
    }

    /// NSOpenPanel scoped to .pixelbay bundles. On user pick, opens a new
    /// editor window. Defaults to `~/Library/Application Support/Pixelbay/
    /// Recordings/` so the picker lands on the directory where
    /// RecordingService writes new bundles.
    @MainActor
    private func pickAndOpenProject() async {
        let panel = NSOpenPanel()
        panel.title = "Open Pixelbay Project"
        if let pixelbayUTI = UTType("com.pixelbay.project") {
            panel.allowedContentTypes = [pixelbayUTI]
        } else {
            // Fallback: treat .pixelbay as a directory bundle. The OS
            // normally vends our exported UTI, but if registration hasn't
            // landed (debug build, fresh install) the user can still pick
            // any directory ending in .pixelbay.
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
        }
        panel.allowsMultipleSelection = false
        panel.directoryURL = OrphanRecoveryModel.recordingsDirectory()
        let response = await withCheckedContinuation { continuation in
            panel.begin { response in continuation.resume(returning: response) }
        }
        guard response == .OK, let url = panel.url else { return }
        openProjectBundle(at: url)
    }

    @ViewBuilder
    private var postOnboardingScene: some View {
        switch recording.phase {
        case .stopped(let result):
            PostCaptureView(
                result: result,
                onNewRecording: { recording.acknowledgeResult() },
                onEditProject: { url in
                    openProjectBundle(at: url)
                    recording.acknowledgeResult()
                }
            )
        default:
            PrecaptureView(
                model: precaptureModel,
                accessibilityGranted: permissions.statuses[.accessibility] == .granted,
                onRequestAccessibility: {
                    // Prompt (registers this binary in the Accessibility list)
                    // rather than just opening the pane — see PermissionProbe.
                    Task { await permissions.request(.accessibility) }
                },
                onRecord: {
                    Task {
                        guard let request = precaptureModel.makeStartRequest() else { return }
                        await recording.start(request)
                    }
                },
                onOpenProject: {
                    Task { await pickAndOpenProject() }
                },
                onSceneRecording: {
                    // Launcher = "fresh scenes session" entry point. Clear
                    // any append-target the editor's Scenes button may have
                    // left behind so this session loads in standalone mode
                    // — without this, a previously-closed project (even one
                    // discarded without saving) would be reused as the merge
                    // target and the new scenes would append into a stale
                    // document instead of producing a fresh merged project.
                    scenesAppendTarget.set(nil)
                    openWindow(id: WindowID.scenes)
                    // Re-derive the (singleton, state-surviving) Scenes window
                    // from disk on reopen — see the notification's definition.
                    NotificationCenter.default.post(name: .pixelbayScenesWindowOpenRequested, object: nil)
                },
                onClose: {
                    // Hover bar ✕ — hide the launcher. The menubar status
                    // item's "Show Pixelbay" reopens it.
                    dismissWindow(id: WindowID.launcher)
                }
            )
            // The .failed phase reuses the picker but flashes a banner so the
            // user can see why the previous attempt failed and try again.
            .overlay(alignment: .top) {
                if case .failed(let message) = recording.phase {
                    failureBanner(message)
                        .padding(20)
                }
            }
            .task {
                // Keep the Accessibility status fresh — if the user grants
                // it via Settings while the picker is open, the toggle
                // un-disables on the next refresh tick (1.5s).
                while !Task.isCancelled {
                    await permissions.refresh()
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                }
            }
        }
    }

    /// Installs (idempotently) the close-interceptor delegate on the launcher
    /// window so the post-capture ✕ routes through a discard confirm. Guards on
    /// the window identity — project/scenes windows own their own delegates.
    private func installLauncherCloseInterceptor(on window: NSWindow) {
        guard window.identifier?.rawValue.contains(WindowID.launcher) == true else { return }
        if window.delegate is LauncherCloseInterceptor { return }
        let interceptor = LauncherCloseInterceptor(recording: recording)
        window.delegate = interceptor
        objc_setAssociatedObject(
            window,
            &LauncherCloseInterceptor.associationKey,
            interceptor,
            .OBJC_ASSOCIATION_RETAIN_NONATOMIC
        )
    }

    private func failureBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: Theme.Spacing.sm) {
            Image(systemName: "xmark.octagon.fill").foregroundStyle(Theme.Color.danger)
            Text(message).font(Theme.Font.body).foregroundStyle(Theme.Color.textPrimary)
            Spacer()
            Button("Dismiss") { recording.acknowledgeResult() }
                .buttonStyle(.pbGhost)
        }
        .padding(Theme.Spacing.md)
        .background(Theme.Color.danger.opacity(0.12), in: RoundedRectangle(cornerRadius: Theme.Radius.medium))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.medium)
                .strokeBorder(Theme.Color.danger.opacity(0.35), lineWidth: Theme.Stroke.hairline)
        )
    }
}

// NSWindowDelegate for the launcher window. During the post-capture review
// (phase == .stopped) the red ✕ would otherwise just close the window — the
// take stays on disk and the user is left with no record bar. Instead we
// intercept it: confirm, then discard the recording and drop back to the
// picker (window stays open so the floating record bar reappears). Every other
// route (onboarding, picker bar, failure banner) closes normally.
//
// Mirrors ProjectCloseInterceptor's pattern: a strong ref is stashed on the
// window via an associated object because NSWindow.delegate is weak.
@MainActor
final class LauncherCloseInterceptor: NSObject, NSWindowDelegate {
    nonisolated(unsafe) static var associationKey: UInt8 = 0

    let recording: RecordingService
    private var promptInFlight = false

    init(recording: RecordingService) {
        self.recording = recording
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard !promptInFlight else { return false }
        // Only the post-capture review is intercepted.
        guard case .stopped = recording.phase else { return true }

        promptInFlight = true
        let alert = NSAlert()
        alert.messageText = "Discard this recording?"
        alert.informativeText = "Closing the review without editing or exporting permanently erases the recording."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Discard")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: sender) { [weak self] response in
            guard let self else { return }
            self.promptInFlight = false
            guard response == .alertFirstButtonReturn else { return }   // Cancel: stay in the review
            // Throw the take away and return to the picker; keep the window
            // open so the floating record bar reappears immediately.
            self.recording.discardStoppedResult()
        }
        return false   // never close via ✕ — we route to the picker instead
    }
}
