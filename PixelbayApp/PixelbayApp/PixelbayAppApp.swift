import AppKit
import KeyboardShortcuts
import OSLog
import Sparkle
import SwiftUI
import UniformTypeIdentifiers

private let log = Logger(subsystem: "com.pixelbay.PixelbayApp", category: "App")

// Window-scene IDs. Stable strings so SwiftUI's window restoration can map
// saved state back to the right scene on relaunch.
enum WindowID {
    static let launcher = "launcher"
    static let project = "project"
    // Phase 5 — singleton scene-recording window. One instance at a time
    // (uses `Window`, not `WindowGroup`) because every scenes session
    // shares the same persistent .pixelbay bundle on disk.
    static let scenes = "scenes"
}

extension KeyboardShortcuts.Name {
    // Default: ⌃⌘R when no recording is live (start), ⌃⌘. when one is.
    // Both are user-rebindable later via a Settings scene.
    static let toggleRecording = Self("toggleRecording", default: .init(.r, modifiers: [.command, .control]))
    // ⌃⌘Z fires only during an active recording; logs a user-stated zoom
    // anchor at the current cursor position. The editor renders these in
    // cyan with a ⌘ glyph so they're distinguishable from auto-generated
    // zooms (slice #11.d).
    static let markZoomPoint = Self("markZoomPoint", default: .init(.z, modifiers: [.command, .control]))
}

// Cross-scene intents. Menu commands and the project windows post these so
// the launcher (which owns RecordingService + post-capture state) can react
// without being directly addressable from a Commands view. NotificationCenter
// is the canonical macOS path for app-wide messaging that doesn't fit a
// scene-scoped @Environment binding.
extension Notification.Name {
    static let pixelbayNewRecordingRequested = Notification.Name("com.pixelbay.newRecordingRequested")
}

@main
struct PixelbayAppApp: App {
    @NSApplicationDelegateAdaptor(PixelbayAppDelegate.self) private var appDelegate
    @State private var recording = RecordingService()
    @State private var hud = RecordingHUDController()
    @State private var appState = AppState()
    // Slice A.2 — shared inter-window state pointing the next-opened
    // Scenes window at a specific editor document for append-merge.
    @State private var scenesAppendTarget = ScenesAppendTarget()

    var body: some Scene {
        // Launcher: singleton window for picker + post-capture + onboarding +
        // orphan recovery. Singleton because the recording state it hosts
        // (RecordingService, picker selections) must not duplicate across
        // windows. `Window` (vs WindowGroup) enforces single-instance.
        Window("Pixelbay", id: WindowID.launcher) {
            ContentView()
                .environment(recording)
                .environment(scenesAppendTarget)
                .onAppear {
                    appState.bindHotkeys(recording: recording)
                    appState.installMenubar(recording: recording)
                }
                .onChange(of: phaseTag(recording.phase)) { _, _ in
                    appState.respondToPhaseChange(recording: recording, hud: hud)
                }
        }
        .defaultSize(width: 920, height: 640)
        .commands {
            // File menu: ⌘N hops back to the launcher and clears any
            // post-capture state so the user lands on the picker. ⌘O opens
            // a project in its own window via openWindow(value:).
            CommandGroup(replacing: .newItem) {
                NewRecordingCommand()
                OpenProjectCommand()
            }
            // Save/Close are bound to the focused project window via
            // FocusedValue. They're disabled when no project window is key.
            CommandGroup(replacing: .saveItem) {
                SaveProjectCommand()
                CloseProjectCommand()
            }
            CommandGroup(replacing: .undoRedo) {
                EditUndoRedoCommands()
            }
            // Phase 5 — "Clean up unused takes" under the File menu.
            // Operates on the focused project window's document; disabled
            // when the focused project has nothing to clean (the helper
            // is cheap and the visibility-gate avoids confusion when the
            // menu item appears available but does nothing).
            CommandGroup(after: .saveItem) {
                CleanupUnusedTakesCommand()
            }
        }

        // Project editor: one window per open .pixelbay bundle. SwiftUI
        // restores these on relaunch via the encoded ProjectWindowID.
        WindowGroup("Project", id: WindowID.project, for: ProjectWindowID.self) { $bundleID in
            ProjectWindow(bundleID: bundleID)
                .environment(scenesAppendTarget)
        }
        .defaultSize(width: 1200, height: 800)

        // Phase 5 — Scenes window. Singleton (`Window`, not `WindowGroup`)
        // because there's exactly one persistent scenes-session bundle on
        // disk per machine; opening the window twice would step on its
        // own state. `.windowResizability(.contentSize)` lets slice 5.6's
        // recording-HUD collapse animate the window between full and
        // compact frame sizes.
        Window("Scene Recording", id: WindowID.scenes) {
            ScenesWindowView()
                .environment(recording)
                .environment(scenesAppendTarget)
        }
        .defaultSize(width: 760, height: 720)
        .windowResizability(.contentSize)
    }

    // SwiftUI's onChange needs Equatable. RecordingService.Phase is Equatable
    // but Result includes [CaptureTrack: TrackStats] which is fine — still,
    // we only care about the case for HUD/menubar visibility, so collapse to
    // a tag string.
    private func phaseTag(_ phase: RecordingService.Phase) -> String {
        switch phase {
        case .idle: return "idle"
        case .preparing: return "preparing"
        case .recording: return "recording"
        case .stopping: return "stopping"
        case .stopped: return "stopped"
        case .failed: return "failed"
        }
    }
}

// AppState collects app-wide side effects (hotkey binding, menubar item,
// HUD visibility) into one main-actor-bound object that ContentView pokes
// from .onAppear and .onChange.
@MainActor
final class AppState {
    private var statusItem: NSStatusItem?
    private var menubarStartItem: NSMenuItem?
    private var menubarStopItem: NSMenuItem?
    private var hotkeysBound = false

    func bindHotkeys(recording: RecordingService) {
        guard !hotkeysBound else { return }
        hotkeysBound = true
        KeyboardShortcuts.onKeyDown(for: .toggleRecording) { [weak recording] in
            guard let recording else { return }
            Task { @MainActor in
                if case .recording = recording.phase {
                    await recording.stop()
                }
                // Note: we deliberately do NOT auto-start here. Starting
                // requires display/cam/mic selections that live in the
                // picker UI. The hotkey is "stop while recording" only;
                // the picker's Record button is the start path. This keeps
                // hotkey behaviour predictable.
            }
        }
        KeyboardShortcuts.onKeyDown(for: .markZoomPoint) { [weak recording] in
            guard let recording else { return }
            Task { @MainActor in
                // Best-effort: silently no-ops outside an active recording
                // (the RecordingService method checks phase itself).
                await recording.markZoomAtCursor()
            }
        }
        log.info("hotkeys bound: toggleRecording, markZoomPoint")
    }

    func installMenubar(recording: RecordingService) {
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "record.circle", accessibilityDescription: "Pixelbay")

        let menu = NSMenu()

        let start = NSMenuItem(title: "Start Recording", action: #selector(MenubarTarget.startTapped), keyEquivalent: "")
        start.target = MenubarTarget.shared
        menu.addItem(start)

        let stop = NSMenuItem(title: "Stop Recording", action: #selector(MenubarTarget.stopTapped), keyEquivalent: "")
        stop.target = MenubarTarget.shared
        menu.addItem(stop)

        menu.addItem(.separator())

        let showWindow = NSMenuItem(title: "Show Pixelbay", action: #selector(MenubarTarget.showWindowTapped), keyEquivalent: "")
        showWindow.target = MenubarTarget.shared
        menu.addItem(showWindow)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit Pixelbay", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)

        item.menu = menu
        self.statusItem = item
        self.menubarStartItem = start
        self.menubarStopItem = stop
        MenubarTarget.shared.recording = recording
        refreshMenubar(recording: recording)
        log.info("menubar status item installed")
    }

    func respondToPhaseChange(recording: RecordingService, hud: RecordingHUDController) {
        switch recording.phase {
        case .recording, .stopping:
            hud.show(service: recording)
        default:
            hud.hide()
        }
        refreshMenubar(recording: recording)
        if let symbol = menubarSymbol(for: recording.phase) {
            statusItem?.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Pixelbay")
        }
    }

    private func refreshMenubar(recording: RecordingService) {
        let isLive = recording.isRecording
        menubarStartItem?.isEnabled = !isLive && recording.canStartRecording
        menubarStopItem?.isEnabled = isLive
    }

    private func menubarSymbol(for phase: RecordingService.Phase) -> String? {
        switch phase {
        case .recording, .stopping: return "record.circle.fill"
        default: return "record.circle"
        }
    }
}

// AppKit menu items can't directly call into SwiftUI state, so route through
// a tiny MainActor-bound NSObject the menu items target.
@MainActor
final class MenubarTarget: NSObject {
    static let shared = MenubarTarget()
    weak var recording: RecordingService?

    @objc func startTapped() {
        showLauncherWindow()
    }

    @objc func stopTapped() {
        guard let recording else { return }
        Task { await recording.stop() }
    }

    @objc func showWindowTapped() {
        showLauncherWindow()
    }

    // Bring the launcher window forward, opening it if it was closed.
    // Project editor windows aren't touched.
    private func showLauncherWindow() {
        NSApp.activate(ignoringOtherApps: true)
        // SwiftUI's openWindow(id:) is the canonical path, but we don't have
        // it here (NSObject, no scene context). Use AppKit's window list as a
        // fallback — find the launcher by its identifier (SwiftUI stamps the
        // scene id onto the window's identifier).
        for window in NSApp.windows where window.identifier?.rawValue.contains(WindowID.launcher) == true {
            window.makeKeyAndOrderFront(nil)
            return
        }
        // Fallback: bring forward the first non-panel main-style window.
        for window in NSApp.windows where window.canBecomeKey && !(window is NSPanel) {
            window.makeKeyAndOrderFront(nil)
            return
        }
    }
}

// MARK: - File menu commands

// "New Recording" — focuses the launcher window and clears any post-capture
// state so the user lands on the picker. Doesn't itself start a recording
// (sources need to be picked first).
private struct NewRecordingCommand: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("New Recording") {
            openWindow(id: WindowID.launcher)
            // ContentView observes this notification and calls
            // recording.acknowledgeResult() so a stuck post-capture state
            // gets cleared back to the picker.
            NotificationCenter.default.post(name: .pixelbayNewRecordingRequested, object: nil)
        }
        .keyboardShortcut("n", modifiers: .command)
    }
}

// "Open Project…" — NSOpenPanel scoped to .pixelbay bundles, then
// openWindow(value:) to spawn an editor window for the picked URL.
private struct OpenProjectCommand: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Open Project…") {
            Task { @MainActor in
                if let url = await pickProjectBundle() {
                    openWindow(value: ProjectWindowID(bundleURL: url))
                }
            }
        }
        .keyboardShortcut("o", modifiers: .command)
    }

    private func pickProjectBundle() async -> URL? {
        let panel = NSOpenPanel()
        panel.title = "Open Pixelbay Project"
        if let pixelbayUTI = UTType("com.pixelbay.project") {
            panel.allowedContentTypes = [pixelbayUTI]
        } else {
            // Fallback if the exported UTI hasn't registered yet (debug
            // build, fresh install): treat .pixelbay as a directory bundle.
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
        }
        panel.allowsMultipleSelection = false
        panel.directoryURL = OrphanRecoveryModel.recordingsDirectory()
        let response = await withCheckedContinuation { continuation in
            panel.begin { response in continuation.resume(returning: response) }
        }
        return response == .OK ? panel.url : nil
    }
}

// "Save" — bound to the focused project window's document via FocusedValue.
// Disabled when no project window is key OR the focused document isn't dirty.
private struct SaveProjectCommand: View {
    @FocusedValue(\.openProjectDocument) private var document

    var body: some View {
        Button("Save") {
            guard let document else { return }
            Task { await document.save() }
        }
        .keyboardShortcut("s", modifiers: .command)
        .disabled(document?.isDirty != true || document?.status == .saving)
    }
}

// Phase 5 — "Clean up unused takes". Operates on the focused project
// window's document via FocusedValue. Removes discarded scene takes'
// media files + project.assets entries, plus orphan assets that aren't
// referenced by any clip (post-merge cleanup). Disabled when there's
// nothing to clean so the menu item doesn't appear to do nothing on
// click.
private struct CleanupUnusedTakesCommand: View {
    @FocusedValue(\.openProjectDocument) private var document

    var body: some View {
        Button("Clean Up Unused Takes") {
            guard let document else { return }
            Task { await document.cleanupUnusedTakes() }
        }
        .disabled(document?.hasOrphanedAssetsOrTakes != true)
    }
}

// "Close Project" — closes the focused project window. The window's
// NSWindowDelegate (ProjectCloseInterceptor) presents the save-on-close
// prompt if the document is dirty.
private struct CloseProjectCommand: View {
    @FocusedValue(\.openProjectDocument) private var document
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        Button("Close Project") {
            // Use AppKit close so the window's NSWindowDelegate gets a chance
            // to intercept (windowShouldClose presents the save-on-close
            // alert). dismissWindow bypasses the delegate.
            NSApp.keyWindow?.performClose(nil)
        }
        .keyboardShortcut("w", modifiers: .command)
        .disabled(document == nil)
    }
}

// MARK: - FocusedValue plumbing

// FocusedValue plumbing: ProjectWindow publishes its document so the Scene
// commands (Save / Close / Edit > Undo/Redo) bind to whichever project
// window is currently focused.
struct OpenProjectFocusedValueKey: FocusedValueKey {
    typealias Value = ProjectDocument
}

extension FocusedValues {
    var openProjectDocument: ProjectDocument? {
        get { self[OpenProjectFocusedValueKey.self] }
        set { self[OpenProjectFocusedValueKey.self] = newValue }
    }
}

// View that lives inside Scene.commands — accesses the focused
// ProjectDocument and routes the Edit menu's Undo/Redo to it. The menu
// items also display "Undo Trim Clip" / "Redo Change Volume" via the
// document's action-name strings, matching the macOS HIG.
struct EditUndoRedoCommands: View {
    @FocusedValue(\.openProjectDocument) private var document

    var body: some View {
        Button(undoTitle) {
            guard let document else { return }
            Task { await document.undo() }
        }
        .keyboardShortcut("z", modifiers: .command)
        .disabled(document?.canUndo != true)

        Button(redoTitle) {
            guard let document else { return }
            Task { await document.redo() }
        }
        .keyboardShortcut("z", modifiers: [.command, .shift])
        .disabled(document?.canRedo != true)
    }

    private var undoTitle: String {
        if let name = document?.undoActionName, document?.canUndo == true {
            return "Undo \(name)"
        }
        return "Undo"
    }

    private var redoTitle: String {
        if let name = document?.redoActionName, document?.canRedo == true {
            return "Redo \(name)"
        }
        return "Redo"
    }
}
