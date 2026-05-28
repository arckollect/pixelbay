import AppKit
import OSLog
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
        .task { orphans.scan() }
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
        case .recording, .stopping:
            recordingPlaceholder
        default:
            PrecaptureView(
                model: precaptureModel,
                accessibilityGranted: permissions.statuses[.accessibility] == .granted,
                onRequestAccessibility: {
                    Task { await permissions.openSettings(for: .accessibility) }
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

    private var recordingPlaceholder: some View {
        VStack(spacing: 16) {
            Image(systemName: "record.circle.fill")
                .font(.system(size: 48))
                .foregroundStyle(.red)
            Text("Recording in progress")
                .font(.title2.bold())
            Text("Use the floating HUD to stop. Pixelbay's own windows are excluded from screen.mov.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 40)
        }
        .padding(40)
        .frame(minWidth: 620, minHeight: 460)
    }

    private func failureBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
            Text(message).font(.callout)
            Spacer()
            Button("Dismiss") { recording.acknowledgeResult() }
        }
        .padding(12)
        .background(.red.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
    }
}
