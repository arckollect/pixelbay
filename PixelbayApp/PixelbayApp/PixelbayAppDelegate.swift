import AppKit
import OSLog
import PixelbayCore

private let log = Logger(subsystem: "com.pixelbay.PixelbayApp", category: "AppDelegate")

// NSApplicationDelegate hook for app-quit save prompts.
//
// SwiftUI's WindowGroup(for:) doesn't go through NSDocumentController, so the
// standard "you have unsaved changes — save before quitting?" prompt doesn't
// fire automatically on Cmd-Q. Without this delegate, Cmd-Q would close every
// project window without surfacing dirty state.
//
// On `applicationShouldTerminate(_:)` we walk NSApp.windows looking for any
// whose delegate is a ProjectCloseInterceptor with a dirty document. If
// there's at least one, we return `.terminateLater` and walk them serially —
// each prompts a Save / Don't Save / Cancel sheet. Cancel aborts the quit;
// otherwise, after the last document is resolved (saved or discarded), we
// reply true and the app terminates.
//
// Per-window close prompts (✕ button, ⌘W) keep their own NSWindowDelegate
// hook in ProjectCloseInterceptor — this delegate only handles the quit
// path.
@MainActor
final class PixelbayAppDelegate: NSObject, NSApplicationDelegate {

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let dirty: [(NSWindow, ProjectCloseInterceptor)] = NSApp.windows.compactMap { window in
            guard let interceptor = window.delegate as? ProjectCloseInterceptor,
                  interceptor.document.isDirty
            else { return nil }
            return (window, interceptor)
        }
        guard !dirty.isEmpty else { return .terminateNow }
        log.info("applicationShouldTerminate: \(dirty.count) dirty project window(s)")
        promptNextDirty(dirty)
        return .terminateLater
    }

    private func promptNextDirty(_ remaining: [(NSWindow, ProjectCloseInterceptor)]) {
        guard let (window, interceptor) = remaining.first else {
            NSApp.reply(toApplicationShouldTerminate: true)
            return
        }
        let document = interceptor.document
        let alert = NSAlert()
        alert.messageText = "Save changes to \"\(document.project.name)\" before quitting?"
        alert.informativeText = "Your changes will be lost if you don't save them."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Don't Save")
        alert.addButton(withTitle: "Cancel")

        // Bring the window forward so the sheet is visible — otherwise the
        // sheet attaches to whichever window happens to be drawn on top.
        window.makeKeyAndOrderFront(nil)

        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            switch response {
            case .alertFirstButtonReturn:
                Task { @MainActor in
                    await document.save()
                    if case .failed = document.status {
                        // Save failed — abort the quit so the user can see
                        // the in-window error banner and decide what to do.
                        NSApp.reply(toApplicationShouldTerminate: false)
                        return
                    }
                    self.promptNextDirty(Array(remaining.dropFirst()))
                }
            case .alertSecondButtonReturn:
                self.promptNextDirty(Array(remaining.dropFirst()))
            default:
                NSApp.reply(toApplicationShouldTerminate: false)
            }
        }
    }
}
