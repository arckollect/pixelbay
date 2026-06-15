import AppKit
import OSLog
import PixelbayDesignSystem
import SwiftUI

private let log = Logger(subsystem: "com.pixelbay.PixelbayApp", category: "RecordingHUD")

// Floating glass bar shown while a recording is live — the only Pixelbay UI on
// screen during capture (the launcher window is ordered out; see
// AppState.respondToPhaseChange). Mounted as a borderless NSPanel so it floats
// above other windows without stealing focus and never enters the window list
// that screen.mov captures. Pixelbay's bundle ID is added to SCContentFilter's
// excludingApplications (RecordingService.start) so this panel — along with the
// picker and post-capture sheet — never appears inside screen.mov.
@MainActor
final class RecordingHUDController {
    private var panel: NSPanel?

    var isVisible: Bool { panel?.isVisible ?? false }

    func show(service: RecordingService) {
        if let panel {
            panel.makeKeyAndOrderFront(nil)
            return
        }
        let view = RecordingHUDView(service: service)
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 348, height: 68),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        // Host the SwiftUI view with NSHostingView (NOT NSHostingController +
        // contentViewController) and clear `sizingOptions`, so the view NEVER
        // pushes a size up to the window. If the host is allowed to drive
        // window size, that size-push fires inside AppKit's layout pass on
        // every timer tick and AppKit aborts with NSGenericException ("more Update
        // Constraints in Window passes than there are views"). The panel owns a
        // fixed size; the hosting view fills it via autoresizing + the SwiftUI
        // root's maxWidth/maxHeight. (The old .titled/.hudWindow panel happened
        // to suppress the size-push; the borderless panel does not, so it must
        // be disabled explicitly.)
        let hostingView = NSHostingView(rootView: view)
        hostingView.sizingOptions = []
        hostingView.frame = NSRect(origin: .zero, size: NSSize(width: 348, height: 68))
        hostingView.autoresizingMask = [.width, .height]
        panel.contentView = hostingView
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        // Borderless + clear so the SwiftUI bar draws its own rounded glass
        // and shadow — same chrome as the launcher picker bar.
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isMovableByWindowBackground = true
        Self.positionBottomCentre(panel)
        panel.orderFrontRegardless()
        self.panel = panel
        log.info("HUD panel shown")
    }

    func hide() {
        guard let panel else { return }
        panel.orderOut(nil)
        self.panel = nil
        log.info("HUD panel hidden")
    }

    // Bottom-centre of the main screen, 24pt above the dock/menu-bar-inset edge
    // — mirrors LauncherWindowChrome.positionBottomCentre so the HUD lands where
    // the picker bar did, rather than pinned to a corner.
    private static func positionBottomCentre(_ panel: NSPanel) {
        guard let visible = NSScreen.main?.visibleFrame else { return }
        let size = panel.frame.size
        let origin = NSPoint(
            x: visible.midX - size.width / 2,
            y: visible.minY + 24
        )
        panel.setFrameOrigin(origin)
    }
}

private struct RecordingHUDView: View {
    @Bindable var service: RecordingService
    @State private var pulse = false
    @State private var confirmDiscard = false

    private var barShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: Theme.Radius.large, style: .continuous)
    }

    var body: some View {
        Group {
            switch service.phase {
            case .recording(let startedAt):
                liveBody(startedAt: startedAt)
            case .stopping:
                stoppingBody
            default:
                EmptyView()
            }
        }
        .padding(.horizontal, Theme.Spacing.md)
        .padding(.vertical, Theme.Spacing.sm)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .pbGlassBar(barShape)
        .overlay(barShape.strokeBorder(Color.white.opacity(0.12), lineWidth: Theme.Stroke.regular))
        // No drop shadow: any shadow renders as a faded grey backdrop box
        // around the bar on light desktops, which reads as unwanted chrome.
        // The white hairline stroke above provides all the edge separation
        // the bar needs — we want only the toolbar visible.
        .padding(Theme.Spacing.sm)   // transparent margin inside the panel
        .confirmationDialog("Discard this recording?", isPresented: $confirmDiscard) {
            Button("Discard Recording", role: .destructive) {
                Task { await service.discard() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This deletes the in-progress recording.")
        }
    }

    private func liveBody(startedAt: Date) -> some View {
        HStack(spacing: Theme.Spacing.sm) {
            // Timer group: pulsing record dot + (scene label) + elapsed time.
            HStack(spacing: Theme.Spacing.sm) {
                Circle()
                    .fill(Theme.Color.recordingRed)
                    .frame(width: 9, height: 9)
                    .opacity(pulse ? 0.3 : 1)
                    .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: pulse)
                    .onAppear { pulse = true }
                    .accessibilityHidden(true)
                // Scenes mode: which scene is recording. nil for normal takes.
                if let sceneLabel = service.sceneLabel {
                    Text(sceneLabel)
                        .font(Theme.Font.cardTitle)
                        .foregroundStyle(Theme.Color.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                TimelineView(.periodic(from: startedAt, by: 1)) { context in
                    Text(formatElapsed(startedAt: startedAt, now: context.date))
                        .font(Theme.Font.monoTimecodeLarge)
                        .foregroundStyle(service.sceneLabel == nil ? Theme.Color.textPrimary : Theme.Color.textSecondary)
                        .monospacedDigit()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            PBDivider(.vertical).frame(height: 28)

            // Actions group. Scenes records into a shared bundle, so Discard /
            // Restart (which delete the recording) are omitted there — only
            // Stop. Normal single recordings keep retry/delete one click away.
            HStack(spacing: Theme.Spacing.sm) {
                if service.sceneLabel == nil {
                    Button {
                        Task { await service.restart() }
                    } label: {
                        Image(systemName: "arrow.counterclockwise")
                    }
                    .buttonStyle(.pbCompact)
                    .help("Restart — discard this take and start over")

                    Button {
                        confirmDiscard = true
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.pbCompact)
                    .help("Discard — delete this recording")
                }

                Button {
                    Task { await service.stop() }
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.pbDestructive)
                .keyboardShortcut(.return, modifiers: [])
            }
        }
    }

    private var stoppingBody: some View {
        HStack(spacing: Theme.Spacing.sm) {
            ProgressView().controlSize(.small)
            Text("Finalising writers…")
                .font(Theme.Font.body)
                .foregroundStyle(Theme.Color.textSecondary)
        }
    }

    private func formatElapsed(startedAt: Date, now: Date) -> String {
        let total = max(0, now.timeIntervalSince(startedAt))
        let wholeSeconds = Int(total.rounded(.down))
        let minutes = wholeSeconds / 60
        let seconds = wholeSeconds % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
}

// Glass recipe promoted to `View.pbGlassBar(_:)` in PixelbayDesignSystem.
