import AppKit
import OSLog
import PixelbayCore
import PixelbayDesignSystem
import SwiftUI

private let log = Logger(subsystem: "com.pixelbay.PixelbayApp", category: "ProjectWindow")

// Scene-content wrapper for the project editor window.
//
// Sits inside `WindowGroup("Project", for: ProjectWindowID.self)`, so each
// open project gets its own NSWindow with native macOS lifecycle (titlebar,
// minimise, full-screen, close button). State per window:
//   • Loads a ProjectDocument from the bundleURL on first appear
//   • Shows a loading or failure placeholder while the load is in flight
//   • Installs an NSWindowDelegate that intercepts `windowShouldClose` to
//     present the save-on-close NSAlert when the document is dirty
//
// The `bundleID` value is optional because WindowGroup(for:) hands `nil`
// in two cases: (a) SwiftUI spawned the window to carry a file-open
// external event (Finder double-click / `open foo.pixelbay`), and (b) it
// restored a window that had no value at the last quit. Neither should be
// a window the user sees: (a) routes the URL through `openWindow(value:)`
// — which focuses an already-open window for that bundle instead of
// duplicating it — and dismisses itself; (b) shows the placeholder for a
// short grace period (in case an external event is about to arrive) and
// then dismisses itself, so an empty window never survives to be restored
// again. Without this, one stray empty "Project" window came back on
// every launch beside the real one.
struct ProjectWindow: View {
    let bundleID: ProjectWindowID?

    @State private var document: ProjectDocument?
    @State private var loadError: String?
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.openWindow) private var openWindow

    /// How long a valueless window waits for a file-open event before
    /// closing itself. External events land within a few ms of the window
    /// appearing; the rest of this budget is just safety margin.
    private static let emptyWindowGrace: Duration = .milliseconds(750)

    var body: some View {
        ZStack {
            if let document {
                ProjectView(document: document)
                    .focusedSceneValue(\.openProjectDocument, document)
                    .background(WindowAccessor { window in
                        installCloseInterceptor(on: window, document: document)
                    })
            } else if let loadError {
                failurePlaceholder(loadError)
            } else if bundleID == nil {
                emptyPlaceholder
            } else {
                loadingPlaceholder
            }
        }
        .frame(minWidth: 1000, minHeight: 700)
        .background(Theme.Color.bgBase)
        .tint(Theme.Color.accent)
        .task(id: bundleID) {
            await loadDocument()
        }
        .onOpenURL { url in
            guard url.pathExtension == "pixelbay" else { return }
            // Dedupes by value: focuses the window already showing this
            // bundle, or opens a new one. Every open project window may
            // receive the same event; the repeated call is a no-op.
            openWindow(value: ProjectWindowID(bundleURL: url.standardizedFileURL))
            // This window only existed to carry the event.
            if bundleID == nil { dismissWindow() }
        }
    }

    private func loadDocument() async {
        guard let bundleID else {
            document = nil
            loadError = nil
            // No bundle: wait briefly for a file-open event to arrive (see
            // the type comment), then close rather than linger as an empty
            // window that restoration would bring back next launch.
            try? await Task.sleep(for: Self.emptyWindowGrace)
            guard !Task.isCancelled else { return }
            log.info("closing valueless project window after grace period")
            dismissWindow()
            return
        }
        document = nil
        loadError = nil
        do {
            let doc = try await ProjectDocument.open(bundleURL: bundleID.bundleURL)
            guard !Task.isCancelled, self.bundleID == bundleID else { return }
            document = doc
        } catch {
            guard !Task.isCancelled, self.bundleID == bundleID else { return }
            log.error("openProject failed: \(String(describing: error), privacy: .public)")
            loadError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private var loadingPlaceholder: some View {
        VStack(spacing: 12) {
            ProgressView().controlSize(.large)
            Text("Loading project…").foregroundStyle(Theme.Color.textSecondary)
        }
    }

    private var emptyPlaceholder: some View {
        VStack(spacing: 12) {
            Image(systemName: "folder.badge.questionmark")
                .font(.system(size: 36))
                .foregroundStyle(Theme.Color.textSecondary)
            Text("No project loaded")
                .font(.title3)
                .foregroundStyle(Theme.Color.textPrimary)
            Text("Open a project from the launcher window to edit.")
                .foregroundStyle(Theme.Color.textSecondary)
        }
        .padding(40)
    }

    private func failurePlaceholder(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 36))
                .foregroundStyle(Theme.Color.warning)
            Text("Couldn't open project")
                .font(.title3.bold())
                .foregroundStyle(Theme.Color.textPrimary)
            Text(message)
                .font(.callout)
                .foregroundStyle(Theme.Color.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            Button("Close Window") { dismissWindow() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(40)
    }

    private func installCloseInterceptor(on window: NSWindow, document: ProjectDocument) {
        // Idempotent: skip if an interceptor for the same document is already
        // installed. WindowAccessor.updateNSView re-fires on every body pass.
        if let existing = window.delegate as? ProjectCloseInterceptor,
           existing.document === document {
            return
        }
        // NSWindow.delegate is a weak reference, so stash a strong reference
        // under an associated object on the window itself.
        let interceptor = ProjectCloseInterceptor(document: document)
        window.delegate = interceptor
        objc_setAssociatedObject(
            window,
            &ProjectCloseInterceptor.associationKey,
            interceptor,
            .OBJC_ASSOCIATION_RETAIN_NONATOMIC
        )
    }
}

// NSWindowDelegate that intercepts close attempts on a project window. When
// the underlying ProjectDocument is dirty, presents a Save / Don't Save /
// Cancel sheet (via NSAlert.beginSheetModal) and only allows the close after
// the user has resolved it. The save itself is async — we tell AppKit "no
// don't close" up-front, run the save, then call `window.close()` on success.
//
// Internal (not private) so PixelbayAppDelegate can find dirty documents
// during applicationShouldTerminate by walking NSApp.windows and casting
// each window.delegate.
@MainActor
final class ProjectCloseInterceptor: NSObject, NSWindowDelegate {
    nonisolated(unsafe) static var associationKey: UInt8 = 0

    let document: ProjectDocument
    private var promptInFlight = false
    private var allowConfirmedClose = false

    init(document: ProjectDocument) {
        self.document = document
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if allowConfirmedClose {
            allowConfirmedClose = false
            return true
        }
        guard !promptInFlight else { return false }
        guard document.isDirty else { return true }

        promptInFlight = true
        let alert = NSAlert()
        alert.messageText = "Save changes to \"\(document.project.name)\" before closing?"
        alert.informativeText = "Your changes will be lost if you don't save them."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Don't Save")
        alert.addButton(withTitle: "Cancel")

        alert.beginSheetModal(for: sender) { [weak self, weak sender] response in
            guard let self else { return }
            self.promptInFlight = false
            switch response {
            case .alertFirstButtonReturn:
                Task { @MainActor in
                    await self.document.save()
                    if case .failed = self.document.status { return }
                    self.allowConfirmedClose = true
                    sender?.close()
                }
            case .alertSecondButtonReturn:
                self.allowConfirmedClose = true
                sender?.close()
            default:
                break // Cancel — leave the window open.
            }
        }
        return false
    }
}

// SwiftUI escape hatch to grab the hosting NSWindow on first appear. Used to
// install the close-interceptor delegate; doesn't render anything visible.
struct WindowAccessor: NSViewRepresentable {
    let onWindow: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            if let window = view.window {
                onWindow(window)
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        // The window may not be available when makeNSView fires (the view
        // hasn't been added to a window's view tree yet). Re-check on update
        // so we eventually catch it.
        if let window = nsView.window {
            onWindow(window)
        }
    }
}
