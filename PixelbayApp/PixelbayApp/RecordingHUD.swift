import AppKit
import OSLog
import SwiftUI

private let log = Logger(subsystem: "com.pixelbay.PixelbayApp", category: "RecordingHUD")

// Floating panel that shows elapsed time + Stop while a recording is live.
// Mounted as an NSPanel so it floats above other windows without stealing
// focus. Pixelbay's bundle ID is added to SCContentFilter's
// excludingApplications (RecordingService.start) so this panel — along with
// the picker and post-capture sheet — never appears inside screen.mov.
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
        let host = NSHostingController(rootView: view)
        // Do NOT enable .preferredContentSize: the HUD body contains a
        // SwiftUI TimelineView(.periodic(every: 0.1)) which forces a
        // SwiftUI re-evaluation 10×/s. With .preferredContentSize the
        // host pushes a fresh size up to the panel during AppKit's own
        // constraint pass, which AppKit treats as an infinite layout
        // loop and aborts with NSGenericException ("more Update
        // Constraints in Window passes than there are views").
        // Instead, the panel owns the size; SwiftUI fits within it.
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 222, height: 68),
            styleMask: [.titled, .nonactivatingPanel, .hudWindow, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        panel.title = "Recording"
        panel.contentViewController = host
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.center()
        // Default to top-right of the main screen so it doesn't sit on top
        // of whatever the user is recording.
        if let screenFrame = NSScreen.main?.visibleFrame {
            let frame = panel.frame
            let origin = NSPoint(
                x: screenFrame.maxX - frame.width - 24,
                y: screenFrame.maxY - frame.height - 24
            )
            panel.setFrameOrigin(origin)
        }
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
}

private struct RecordingHUDView: View {
    @Bindable var service: RecordingService

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
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func liveBody(startedAt: Date) -> some View {
        HStack(spacing: 12) {
            Circle()
                .fill(.red)
                .frame(width: 10, height: 10)
                .opacity(0.95)
                .accessibilityHidden(true)
            TimelineView(.periodic(from: startedAt, by: 0.1)) { context in
                Text(formatElapsed(startedAt: startedAt, now: context.date))
                    .font(.system(.title3, design: .monospaced))
                    .monospacedDigit()
            }
            Spacer(minLength: 0)
            Button {
                Task { await service.stop() }
            } label: {
                Label("Stop", systemImage: "stop.fill")
                    .labelStyle(.titleAndIcon)
            }
            .controlSize(.regular)
            .keyboardShortcut(.return, modifiers: [])
        }
    }

    private var stoppingBody: some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text("Finalising writers…")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private func formatElapsed(startedAt: Date, now: Date) -> String {
        let total = max(0, now.timeIntervalSince(startedAt))
        let minutes = Int(total) / 60
        let seconds = total - Double(minutes * 60)
        return String(format: "%02d:%05.2f", minutes, seconds)
    }
}
