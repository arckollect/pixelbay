import AppKit
import OSLog
import PixelbayCore
import PixelbayDesignSystem
import PixelbayPermissions
import SwiftUI

private let log = Logger(subsystem: "com.pixelbay.PixelbayApp", category: "ScenesWindowView")

// Phase 5 — top-level view inside the Scene Recording window. Three parts:
//   - Top: defaults pickers (display / camera / mic / system-audio /
//     log-clicks). Every newly added scene inherits these.
//   - Middle: scrolling list of scene rows. Drag-to-reorder via .onMove.
//   - Bottom: Add Scene (left) + Merge (right, disabled until at least one
//     scene has a take).
//
// The model is created async in `.task` because opening the persistent
// .pixelbay bundle on disk takes a beat; until it lands we render a
// progress placeholder. Once loaded, every mutation goes through the
// `@Bindable` model and auto-persists via the 250 ms debounce.

struct ScenesWindowView: View {
    @Environment(RecordingService.self) private var recording
    @Environment(ScenesAppendTarget.self) private var scenesAppendTarget
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var modelState: ModelState = .loading
    @State private var catalog = ScenesSourceCatalog()
    @State private var mergeConfirmationPresented: Bool = false
    @State private var mergeSkippedSceneCount: Int = 0
    @State private var showSourcesPopover: Bool = false
    @State private var permissions = PermissionViewModel(
        coordinator: PermissionCoordinator(probe: .live)
    )

    enum ModelState {
        case loading
        case ready(ScenesSessionModel)
        case failed(String)
    }

    var body: some View {
        Group {
            switch modelState {
            case .loading:
                loadingView
                    .frame(minWidth: 760, minHeight: 640)
            case .failed(let message):
                failureView(message)
                    .frame(minWidth: 760, minHeight: 640)
            case .ready(let model):
                readyView(model: model)
            }
        }
        .task {
            await loadModel()
            await catalog.reload()
            // Seed the global default sources up-front. Previously this lived
            // in DefaultsBlock.onAppear, but that block now only renders inside
            // the Sources popover — so without seeding here a fresh window has
            // no default display and the first Record silently fails with
            // "No display selected."
            seedDefaultsIfMissing()
        }
    }

    /// Picks sensible default sources (primary display, etc.) from the freshly
    /// reloaded catalog when the session has none yet. Mirrors DefaultsBlock's
    /// own seeding so the global popover and the window agree.
    private func seedDefaultsIfMissing() {
        guard case .ready(let model) = modelState else { return }
        let seeded = catalog.seedingDefaultsIfMissing(
            from: (
                displayID: model.session.defaults.displayID,
                cameraUniqueID: model.session.defaults.cameraUniqueID,
                micUniqueID: model.session.defaults.micUniqueID
            )
        )
        var defaults = model.session.defaults
        var changed = false
        if defaults.displayID != seeded.displayID {
            defaults.displayID = seeded.displayID
            changed = true
        }
        if defaults.cameraUniqueID != seeded.cameraUniqueID {
            defaults.cameraUniqueID = seeded.cameraUniqueID
            changed = true
        }
        if defaults.micUniqueID != seeded.micUniqueID {
            defaults.micUniqueID = seeded.micUniqueID
            changed = true
        }
        if changed {
            model.updateDefaults(defaults)
        }
    }

    // MARK: - Loaded state

    @ViewBuilder
    private func readyView(model: ScenesSessionModel) -> some View {
        // No compact in-window HUD: while a scene is recording the whole Scenes
        // window is hidden (AppState.reconcileScenesWindow) so the floating
        // RecordingHUD — which shows the "Scene N" label and Stop — is the only
        // capture UI, matching the single-recording flow. The window always
        // renders its full body; it reappears (here) once the take finishes.
        fullBody(model: model)
            // Intercept the window ✕ so closing with un-merged takes prompts to
            // discard them (see ScenesCloseInterceptor), then closing reshows
            // the launcher picker via the existing willClose → reconcileLauncher.
            .background(WindowAccessor { window in
                installScenesCloseInterceptor(on: window, model: model)
            })
    }

    /// Installs (idempotently) the close-interceptor delegate on the Scenes
    /// window, bound to the loaded model. Guards on window identity so it never
    /// touches the launcher / project windows.
    private func installScenesCloseInterceptor(on window: NSWindow, model: ScenesSessionModel) {
        guard window.identifier?.rawValue.contains(WindowID.scenes) == true else { return }
        if let existing = window.delegate as? ScenesCloseInterceptor, existing.model === model {
            return
        }
        let interceptor = ScenesCloseInterceptor(model: model)
        window.delegate = interceptor
        // The Scenes window always opens at its default size — we never want a
        // prior resize (this launch or a previous one) to stick. A new
        // interceptor means a fresh window/session, so snap it to default here.
        ScenesCloseInterceptor.applyDefaultSize(to: window)
        objc_setAssociatedObject(
            window,
            &ScenesCloseInterceptor.associationKey,
            interceptor,
            .OBJC_ASSOCIATION_RETAIN_NONATOMIC
        )
    }

    private func fullBody(model: ScenesSessionModel) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            historySection(model: model)
            sceneGrid(model: model)
            bottomBar(model: model)
        }
        .frame(minWidth: 760, minHeight: 640)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Theme.Color.bgBase)
        .alert(
            "Merge \(mergedSceneCount(in: model)) of \(model.session.scenes.count) scenes?",
            isPresented: $mergeConfirmationPresented
        ) {
            Button("Merge") {
                Task {
                    try? model.persistNow()
                    if let appendTarget = model.appendTarget {
                        // Slice A.2 — editor-launched flow. Append new
                        // scenes to the editor's existing timeline, leave
                        // the editor window open, dismiss the scenes window.
                        _ = await model.mergeAppendingTo(
                            document: appendTarget,
                            onMergedDismiss: { dismissWindow(id: WindowID.scenes) }
                        )
                    } else {
                        _ = await model.merge(
                            opening: openWindow,
                            onMergedDismiss: { dismissWindow(id: WindowID.scenes) }
                        )
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            if model.appendTarget != nil {
                Text("Empty scenes will be skipped. The new scenes will append to the existing project timeline; this scenes session resets to five fresh rows.")
            } else {
                Text("Empty scenes will be skipped. The merged project will open in a new editor window; this scenes session will be archived for the next one you start.")
            }
        }
    }

    @ViewBuilder
    private func historySection(model: ScenesSessionModel) -> some View {
        // Only present in append mode (editor opened the scenes window with
        // a target). Empty in fresh-session mode — no history to show.
        if model.appendTarget != nil, !model.historyRows.isEmpty {
            DisclosureGroup {
                List {
                    ForEach(Array(model.historyRows.enumerated()), id: \.element.id) { idx, row in
                        SceneHistoryRowView(
                            model: model,
                            row: row,
                            historyIndex: idx
                        )
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                    }
                    .onMove { indices, destination in
                        guard let source = indices.first else { return }
                        Task { await model.moveHistoryRow(from: source, to: destination) }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .frame(maxHeight: 240)
            } label: {
                HStack(spacing: Theme.Spacing.xs) {
                    Image(systemName: "clock.arrow.circlepath")
                        .foregroundStyle(Theme.Color.textSecondary)
                    Text("History (\(model.historyRows.count) merged \(model.historyRows.count == 1 ? "scene" : "scenes"))")
                        .font(Theme.Font.cardTitle)
                        .foregroundStyle(Theme.Color.textSecondary)
                }
            }
            .tint(Theme.Color.accent)
            .padding(.horizontal, 20)
            .padding(.top, 16)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            HStack(spacing: Theme.Spacing.md) {
                appMark
                Text("Scene Recording")
                    .font(Theme.Font.displayTitleHeavy)
                    .foregroundStyle(Theme.Color.textPrimary)
            }
            Text("Record one scene at a time. Re-record to add another take. Merge stitches the active takes into a normal Pixelbay project.")
                .font(.system(size: 14))
                .foregroundStyle(Theme.Color.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Theme.Spacing.xl)
        .padding(.top, Theme.Spacing.xl)
        .padding(.bottom, Theme.Spacing.md)
        .background(Theme.Color.bgDeep)
    }

    // The app icon doubles as the brand mark in the header (no dedicated logo
    // imageset ships today). Rounded + hairline border to match the Figma chip.
    private var appMark: some View {
        Image(nsImage: NSApp.applicationIconImage)
            .resizable()
            .frame(width: 40, height: 40)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous)
                    .stroke(Theme.Color.borderSubtle, lineWidth: Theme.Stroke.hairline)
            )
    }

    private func sceneGrid(model: ScenesSessionModel) -> some View {
        // 3-up gallery that reflows to 2 / 1 columns as the window narrows.
        // Drag a tile onto another to reorder (replaces the old List.onMove).
        GeometryReader { geo in
            let columns = columnCount(for: geo.size.width)
            let layout = Array(
                // Top-align cells: real tiles now carry an action bar beneath
                // them, so they're taller than the AddSceneTile — aligning to
                // top keeps every tile's top edge on the same line.
                repeating: GridItem(.flexible(), spacing: Theme.Spacing.xl, alignment: .top),
                count: columns
            )
            ScrollView {
                LazyVGrid(columns: layout, spacing: Theme.Spacing.xl) {
                    ForEach(model.session.scenes.indices, id: \.self) { idx in
                        SceneTileView(model: model, sceneIndex: idx, catalog: catalog)
                            .draggable(String(idx)) {
                                // Lightweight drag preview.
                                RoundedRectangle(cornerRadius: Theme.Radius.large, style: .continuous)
                                    .fill(Theme.Color.bgElevated)
                                    .frame(width: 160, height: 90)
                            }
                            .dropDestination(for: String.self) { items, _ in
                                guard let first = items.first, let from = Int(first), from != idx
                                else { return false }
                                model.moveScene(from: from, to: from < idx ? idx + 1 : idx)
                                return true
                            }
                    }
                    // Trailing "ghost" tile — always the last cell, invites
                    // adding another scene.
                    AddSceneTile { model.addScene() }
                }
                // Even inset all round — 16:9 tiles are shorter than the old
                // 3:2 ones, so match the vertical padding to the horizontal
                // (was lg) to keep balanced gutters around the grid.
                .padding(.horizontal, Theme.Spacing.xl)
                .padding(.vertical, Theme.Spacing.xl)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.Color.bgBase)
    }

    /// Column count chosen by available width: 3-up wide, 2-up medium, 1-up narrow.
    private func columnCount(for width: CGFloat) -> Int {
        if width >= 1100 { return 3 }
        if width >= 740 { return 2 }
        return 1
    }

    private func bottomBar(model: ScenesSessionModel) -> some View {
        HStack(spacing: Theme.Spacing.md) {
            Button {
                model.addScene()
            } label: {
                Label("Add Scene", systemImage: "plus")
            }
            .buttonStyle(.pbSecondary)

            Button {
                showSourcesPopover = true
            } label: {
                Label("Sources", systemImage: "slider.horizontal.3")
            }
            .buttonStyle(.pbSecondary)
            .popover(isPresented: $showSourcesPopover, arrowEdge: .bottom) {
                DefaultsBlock(
                    model: model,
                    catalog: catalog,
                    permissions: permissions,
                    onApplied: { showSourcesPopover = false }
                )
                .tint(Theme.Color.accent)
                .padding(Theme.Spacing.lg)
                .frame(width: 320)
            }

            Menu {
                Button("Clean Up Unused Takes") {
                    Task { await model.cleanupUnusedTakes() }
                }
                .disabled(!hasDiscardedTakes(model: model))
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .controlSize(.large)
            .fixedSize()
            .tint(Theme.Color.accent)

            Spacer()

            Button {
                mergeSkippedSceneCount = model.session.scenes.count - mergedSceneCount(in: model)
                mergeConfirmationPresented = true
            } label: {
                Label("Merge", systemImage: "rectangle.stack.fill")
            }
            .buttonStyle(.pbPrimary)
            .disabled(!hasAnyRecordedTake(model: model))
        }
        .padding(20)
        .background(Theme.Color.bgDeep)
    }

    private func hasDiscardedTakes(model: ScenesSessionModel) -> Bool {
        model.session.scenes.contains { $0.takes.count > 1 }
    }

    // MARK: - Loading / failure

    private var loadingView: some View {
        VStack(spacing: Theme.Spacing.md) {
            ProgressView()
            Text("Opening scenes bundle…")
                .font(Theme.Font.body)
                .foregroundStyle(Theme.Color.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.Color.bgBase)
    }

    private func failureView(_ message: String) -> some View {
        VStack(spacing: Theme.Spacing.md) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 36))
                .foregroundStyle(Theme.Color.warning)
            Text("Couldn't open scenes bundle")
                .font(Theme.Font.sectionTitle)
                .foregroundStyle(Theme.Color.textPrimary)
            Text(message)
                .font(Theme.Font.body)
                .foregroundStyle(Theme.Color.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            Button("Retry") {
                Task { await loadModel() }
            }
            .buttonStyle(.pbSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.Color.bgBase)
    }

    // MARK: - Helpers

    @MainActor
    private func loadModel() async {
        // Slice A.2 — snapshot the singleton's URL up-front so the rest of
        // this load runs against a frozen value. Clear the singleton
        // immediately AFTER the snapshot so a future window-open (e.g. the
        // launcher's "Scene Recording" button) that didn't go through the
        // editor's Scenes button never re-inherits this URL. Without this
        // clear, the target was sticky across window dismissals and a
        // user who closed their editor without saving would see their next
        // launcher-initiated scenes session silently append-merge into the
        // discarded project instead of producing a fresh one.
        //
        // Reading bundleURL is side-effect-free, but `loadModel()` runs from
        // `.task`, whose synchronous prefix executes inside the view-update
        // pass. Mutating shared state there — `scenesAppendTarget.set(nil)`
        // (an @Observable other windows read) and `modelState` — trips
        // "Modifying state during view update". A single yield reschedules
        // the mutations after the current update completes; the clear still
        // lands long before any future window-open could re-read the target.
        let targetURL = scenesAppendTarget.bundleURL
        await Task.yield()
        guard !Task.isCancelled else { return }
        scenesAppendTarget.set(nil)
        modelState = .loading
        do {
            let model: ScenesSessionModel
            if let targetURL {
                let document = try await ProjectDocument.open(bundleURL: targetURL)
                guard !Task.isCancelled else { return }
                model = try await ScenesSessionModel.openForAppendingTo(
                    document: document,
                    recording: recording
                )
            } else {
                model = try await ScenesSessionModel.openOrCreatePersistent(recording: recording)
            }
            guard !Task.isCancelled else { return }
            modelState = .ready(model)
        } catch {
            guard !Task.isCancelled else { return }
            log.error("openOrCreatePersistent failed: \(String(describing: error), privacy: .public)")
            modelState = .failed(error.localizedDescription)
        }
    }

    private func hasAnyRecordedTake(model: ScenesSessionModel) -> Bool {
        model.session.scenes.contains { $0.activeTake != nil }
    }

    private func mergedSceneCount(in model: ScenesSessionModel) -> Int {
        model.session.scenes.filter { $0.activeTake != nil }.count
    }
}

// MARK: - Defaults block

private struct DefaultsBlock: View {
    let model: ScenesSessionModel
    let catalog: ScenesSourceCatalog
    let permissions: PermissionViewModel
    /// Called after a save button commits the draft — the parent closes the
    /// popover in response.
    let onApplied: () -> Void

    /// Staged source config. Editing the pickers only mutates this draft —
    /// nothing reaches the scene tiles (or the session defaults) until the
    /// user presses one of the apply buttons. Snapshotted from the live
    /// defaults on each presentation (popover content is rebuilt per open).
    @State private var draft: ScenesGlobalDefaults

    init(
        model: ScenesSessionModel,
        catalog: ScenesSourceCatalog,
        permissions: PermissionViewModel,
        onApplied: @escaping () -> Void
    ) {
        self.model = model
        self.catalog = catalog
        self.permissions = permissions
        self.onApplied = onApplied
        _draft = State(initialValue: model.session.defaults)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            Text("Scene sources")
                .font(Theme.Font.cardTitle)
                .foregroundStyle(Theme.Color.textSecondary)
            displayPicker
            cameraPicker
            microphonePicker
            Toggle("Capture system audio", isOn: $draft.includeSystemAudio)
            clickLogToggle
            PBDivider()
            applyButtons
        }
        .onAppear { seedDraftIfMissing() }
    }

    private var applyButtons: some View {
        // Scenes whose sources have been individually customised. The
        // "except custom" button only appears when there's something to skip.
        let customCount = model.session.scenes.filter { $0.sourceOverride.hasAnyOverride }.count
        return VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            VStack(alignment: .leading, spacing: 4) {
                Button {
                    model.applyDefaults(draft, includingCustom: true)
                    onApplied()
                } label: {
                    Label("Apply to All Scenes", systemImage: "square.on.square")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.pbPrimary)
                Text(customCount == 0
                     ? "Saves these sources to every scene."
                     : "Saves to every scene, replacing \(customCount) custom one\(customCount == 1 ? "" : "s").")
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.Color.textSecondary)
            }
            if customCount > 0 {
                VStack(alignment: .leading, spacing: 4) {
                    Button {
                        model.applyDefaults(draft, includingCustom: false)
                        onApplied()
                    } label: {
                        Label("Apply Except Custom", systemImage: "square.on.square.dashed")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.pbSecondary)
                    Text("Leaves \(customCount) custom scene\(customCount == 1 ? "" : "s") unchanged.")
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.Color.textSecondary)
                }
            }
        }
    }

    private var displayPicker: some View {
        Picker("Display", selection: $draft.displayID) {
            if catalog.displays.isEmpty {
                Text("No displays available").tag(UInt32?.none)
            }
            ForEach(catalog.displays) { display in
                Text(display.localizedName).tag(UInt32?.some(display.id))
            }
        }
        .pickerStyle(.menu)
    }

    private var cameraPicker: some View {
        Picker("Camera", selection: $draft.cameraUniqueID) {
            Text("None").tag(String?.none)
            ForEach(catalog.cameras) { cam in
                Text(cam.localizedName).tag(String?.some(cam.id))
            }
        }
        .pickerStyle(.menu)
    }

    private var microphonePicker: some View {
        Picker("Microphone", selection: $draft.micUniqueID) {
            Text("None").tag(String?.none)
            ForEach(catalog.microphones) { mic in
                Text(mic.localizedName).tag(String?.some(mic.id))
            }
        }
        .pickerStyle(.menu)
    }

    private var clickLogToggle: some View {
        let accessibilityGranted = permissions.statuses[.accessibility] == .granted
        return VStack(alignment: .leading, spacing: 4) {
            Toggle("Track cursor (zoom follow + auto-zoom)", isOn: $draft.logClicks)
                .disabled(!accessibilityGranted)
            if !accessibilityGranted {
                Text("Requires Accessibility permission.")
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.Color.textSecondary)
            }
        }
    }

    /// Fills nil source fields on the draft with sensible catalog picks so the
    /// pickers open on a real selection. Draft-only — the session defaults
    /// aren't touched until the user presses an apply button. (The session's
    /// own defaults are independently seeded at window load by
    /// `ScenesWindowView.seedDefaultsIfMissing`, so recording works even if
    /// this popover is never opened.)
    private func seedDraftIfMissing() {
        let seeded = catalog.seedingDefaultsIfMissing(
            from: (
                displayID: draft.displayID,
                cameraUniqueID: draft.cameraUniqueID,
                micUniqueID: draft.micUniqueID
            )
        )
        draft.displayID = seeded.displayID
        draft.cameraUniqueID = seeded.cameraUniqueID
        draft.micUniqueID = seeded.micUniqueID
    }
}

// NSWindowDelegate for the Scene Recording window. Closing the window with
// un-merged takes would silently abandon (but keep on disk) the recorded
// media; instead we intercept the ✕: confirm, then discard the whole scenes
// session (delete its bundle) and let the close proceed — the existing
// willClose → AppState.reconcileLauncher brings the launcher picker back.
//
// Only prompts in `.idle` with recorded takes: a merge sets `.merged` before
// dismissing the window (so the merge's own dismiss never trips the prompt),
// and an empty session closes silently. Mirrors LauncherCloseInterceptor /
// ProjectCloseInterceptor (strong ref stashed via associated object because
// NSWindow.delegate is weak).
@MainActor
final class ScenesCloseInterceptor: NSObject, NSWindowDelegate {
    nonisolated(unsafe) static var associationKey: UInt8 = 0

    let model: ScenesSessionModel
    private var promptInFlight = false
    private var confirmedClose = false

    /// The Scenes window always opens at this content size. We deliberately do
    /// not persist its frame — see `applyDefaultSize`.
    static let defaultContentSize = NSSize(width: 1200, height: 800)

    init(model: ScenesSessionModel) {
        self.model = model
    }

    /// Force `window` back to the default content size, centred. Called when a
    /// fresh interceptor is installed and again in `windowWillClose` (while the
    /// window is hidden), so the next open is always the default size even if
    /// the user resized the last session.
    static func applyDefaultSize(to window: NSWindow) {
        window.setContentSize(defaultContentSize)
        window.center()
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        Self.applyDefaultSize(to: window)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if confirmedClose { return true }
        guard !promptInFlight else { return false }
        // Only the interactive idle state with captured media needs a prompt.
        // A merge (phase `.merged`/`.finalizing`) or an empty session closes
        // straight through.
        guard case .idle = model.phase, model.hasRecordedTakes else { return true }

        promptInFlight = true
        let alert = NSAlert()
        alert.messageText = "Discard scene recordings?"
        alert.informativeText = "Closing Scene Recording permanently erases the takes you've recorded. Merge them into a project first if you want to keep them."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Discard")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: sender) { [weak self, weak sender] response in
            guard let self else { return }
            self.promptInFlight = false
            guard response == .alertFirstButtonReturn else { return }   // Cancel: stay open
            // Throw the takes away (and reset the session to fresh tiles so a
            // reopen isn't stale), then actually close — willClose →
            // reconcileLauncher reshows the picker for a new recording.
            self.model.discardSessionAndReset()
            self.confirmedClose = true
            sender?.close()
        }
        return false
    }
}

