import AppKit
import OSLog
import PixelbayCore
import PixelbayDesignSystem
import PixelbayPermissions
import SwiftUI

private let log = Logger(subsystem: "com.pixelbay.PixelbayApp", category: "ScenesWindowView")

// Phase 5 — top-level view inside the Scene Recording window.
//
//   - Titlebar: native unified toolbar (same chrome as the editor). The title
//     is the window's, the subtitle is a live "2 of 5 recorded · 1:24"
//     summary, and the actions — Add Scene / Sources / ⋯ — live as toolbar
//     items so the content area is just the scenes.
//   - Body: (History, append mode only) + the scene grid.
//   - Bottom bar: a one-line hint that tracks the session's state on the
//     left, the Merge CTA on the right.
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
    /// Flips once after the first grid appears so the cards can stagger in.
    /// Stays true for the life of the (singleton) window, so reopens and
    /// reloads don't replay the entrance.
    @State private var gridDidAppear: Bool = false
    @State private var permissions = PermissionViewModel(
        coordinator: PermissionCoordinator(probe: .live)
    )

    enum ModelState {
        case loading
        case ready(ScenesSessionModel)
        case failed(String)

        /// Coarse key for the state crossfade — `ScenesSessionModel` isn't
        /// Equatable, and only the case change should animate anyway.
        var transitionKey: Int {
            switch self {
            case .loading: return 0
            case .ready: return 1
            case .failed: return 2
            }
        }
    }

    var body: some View {
        Group {
            switch modelState {
            case .loading:
                loadingView
                    .frame(minWidth: 760, minHeight: 640)
                    .transition(.opacity)
            case .failed(let message):
                failureView(message)
                    .frame(minWidth: 760, minHeight: 640)
                    .transition(.opacity)
            case .ready(let model):
                readyView(model: model)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.18), value: modelState.transitionKey)
        .task { await reloadSession(showLoading: true) }
        .onReceive(NotificationCenter.default.publisher(for: .pixelbayScenesWindowOpenRequested)) { _ in
            // The Scenes window is a singleton whose @State (this view + model)
            // survives a close/reopen, so `.task` does NOT re-run on the next
            // open — re-derive a fresh model from disk so the reopened modal
            // never shows the prior session's stale state. Guard so this only
            // fires on a genuine reopen: on the first open `modelState` is still
            // `.loading` (the `.task` owns it), so this no-ops (no double load).
            guard case .ready = modelState else { return }
            Task { await reloadSession(showLoading: false) }
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
            historySection(model: model)
            sceneGrid(model: model)
            bottomBar(model: model)
        }
        .frame(minWidth: 760, minHeight: 640)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Theme.Color.bgBase)
        .navigationSubtitle(subtitle(for: model))
        .toolbar { toolbarContent(model: model) }
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

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private func toolbarContent(model: ScenesSessionModel) -> some ToolbarContent {
        ToolbarItemGroup {
            Button {
                model.addScene()
            } label: {
                Label("Add Scene", systemImage: "plus")
            }
            .help("Add another scene")

            Button {
                showSourcesPopover = true
            } label: {
                Label("Sources", systemImage: "slider.horizontal.3")
            }
            .help("Default display, camera and microphone for every scene")
            .popover(isPresented: $showSourcesPopover, arrowEdge: .bottom) {
                DefaultsBlock(
                    model: model,
                    catalog: catalog,
                    permissions: permissions,
                    onApplied: { showSourcesPopover = false }
                )
                .tint(Theme.Color.accent)
            }

            Menu {
                Button("Clean Up Unused Takes") {
                    Task { await model.cleanupUnusedTakes() }
                }
                .disabled(!hasDiscardedTakes(model: model))
            } label: {
                Label("More", systemImage: "ellipsis.circle")
            }
            .help("More")
        }
    }

    /// Titlebar subtitle: the one-glance state of the session.
    private func subtitle(for model: ScenesSessionModel) -> String {
        let total = model.session.scenes.count
        let recorded = mergedSceneCount(in: model)
        guard recorded > 0 else {
            return "\(total) scene\(total == 1 ? "" : "s") · nothing recorded yet"
        }
        return "\(recorded) of \(total) recorded · \(durationLabel(totalDuration(in: model)))"
    }

    // MARK: - History (append mode)

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
                PBSectionHeader("Already in project", style: .caps) {
                    Text("\(model.historyRows.count)")
                        .font(Theme.Font.caption)
                        .monospacedDigit()
                        .foregroundStyle(Theme.Color.textTertiary)
                }
            }
            .tint(Theme.Color.textSecondary)
            .padding(.horizontal, Theme.Spacing.xl)
            .padding(.top, Theme.Spacing.lg)
        }
    }

    // MARK: - Grid

    private func sceneGrid(model: ScenesSessionModel) -> some View {
        // 3-up gallery that reflows to 2 / 1 columns as the window narrows.
        // Reordering (drag a card onto another) lives inside SceneTileView so
        // the target card can show its own drop ring.
        GeometryReader { geo in
            let columns = columnCount(for: geo.size.width)
            let layout = Array(
                // Top-align cells: real cards carry a footer, so they're
                // taller than the AddSceneTile — aligning to top keeps every
                // card's top edge on the same line.
                repeating: GridItem(.flexible(), spacing: Theme.Spacing.xl, alignment: .top),
                count: columns
            )
            ScrollView {
                LazyVGrid(columns: layout, spacing: Theme.Spacing.xl) {
                    ForEach(model.session.scenes.indices, id: \.self) { idx in
                        SceneTileView(model: model, sceneIndex: idx, catalog: catalog)
                            .staggeredEntrance(index: idx, appeared: gridDidAppear)
                    }
                    // Trailing "ghost" cell — always last, invites adding
                    // another scene.
                    AddSceneTile { model.addScene() }
                        .staggeredEntrance(index: model.session.scenes.count, appeared: gridDidAppear)
                }
                .padding(Theme.Spacing.xl)
            }
            .onAppear {
                // One frame later so the initial layout lands at opacity 0
                // and the rise is actually visible.
                guard !gridDidAppear else { return }
                DispatchQueue.main.async { gridDidAppear = true }
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

    // MARK: - Bottom bar

    private func bottomBar(model: ScenesSessionModel) -> some View {
        HStack(spacing: Theme.Spacing.md) {
            Text(hint(for: model))
                .font(Theme.Font.body)
                .foregroundStyle(Theme.Color.textSecondary)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer()

            Button {
                mergeSkippedSceneCount = model.session.scenes.count - mergedSceneCount(in: model)
                mergeConfirmationPresented = true
            } label: {
                Label(mergeTitle(for: model), systemImage: "rectangle.stack.fill")
            }
            .buttonStyle(.pbPrimary)
            .disabled(!hasAnyRecordedTake(model: model))
            .keyboardShortcut(.return, modifiers: .command)
            .help(model.appendTarget != nil
                  ? "Append the recorded scenes to the open project (⌘↩)"
                  : "Stitch the recorded scenes into a new project (⌘↩)")
        }
        .padding(.horizontal, Theme.Spacing.xl)
        .padding(.vertical, Theme.Spacing.lg)
        .background(Theme.Color.bgDeep)
        .overlay(alignment: .top) { PBDivider() }
    }

    /// Bottom-left copy that changes with the session so the window teaches
    /// itself: how to start, what merge does, what's left.
    private func hint(for model: ScenesSessionModel) -> String {
        let total = model.session.scenes.count
        let recorded = mergedSceneCount(in: model)
        if recorded == 0 {
            return "Click a scene to record it. Reshoot for another take — Merge stitches the takes into one project."
        }
        if recorded == total {
            return "Every scene is recorded. Merge when you're happy with the takes."
        }
        let remaining = total - recorded
        return "\(remaining) scene\(remaining == 1 ? "" : "s") still empty — they're skipped when you merge."
    }

    private func mergeTitle(for model: ScenesSessionModel) -> String {
        let recorded = mergedSceneCount(in: model)
        let noun = "Scene\(recorded == 1 ? "" : "s")"
        if model.appendTarget != nil {
            return recorded > 0 ? "Add \(recorded) \(noun) to Project" : "Add to Project"
        }
        return recorded > 0 ? "Merge \(recorded) \(noun)" : "Merge"
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

    /// Loads the session model + source catalog and seeds default sources, in
    /// the order the window needs. Runs on first open (`.task`, with the
    /// spinner) and on every launcher reopen (`showLoading: false`, swapping the
    /// fresh model in without a spinner flash). Seeding here is load-bearing:
    /// the global defaults used to be seeded in `DefaultsBlock.onAppear`, but
    /// that block now only renders inside the Sources popover, so without this a
    /// fresh window has no default display and the first Record fails with
    /// "No display selected."
    @MainActor
    private func reloadSession(showLoading: Bool) async {
        await loadModel(showLoading: showLoading)
        await catalog.reload()
        seedDefaultsIfMissing()
    }

    @MainActor
    private func loadModel(showLoading: Bool = true) async {
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
        // On a reopen reload we keep the prior grid on screen until the fresh
        // model is ready, avoiding a spinner flash; first load shows the spinner.
        if showLoading { modelState = .loading }
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

    private func totalDuration(in model: ScenesSessionModel) -> Double {
        model.session.scenes.reduce(0) { $0 + ($1.activeTake?.durationSeconds ?? 0) }
    }

    private func durationLabel(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

// MARK: - Staggered entrance

private extension View {
    /// First-appearance rise for grid cells: each card fades in and lifts
    /// 6pt, 35 ms after the one before it. Decorative and one-shot — once
    /// `appeared` is true the modifier is inert, so reloads and reorders never
    /// replay it.
    func staggeredEntrance(index: Int, appeared: Bool) -> some View {
        self
            .opacity(appeared ? 1 : 0)
            .offset(y: appeared ? 0 : 6)
            .animation(
                .easeOut(duration: 0.28).delay(Double(min(index, 11)) * 0.035),
                value: appeared
            )
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
        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Default Sources")
                    .font(Theme.Font.sectionTitle)
                    .foregroundStyle(Theme.Color.textPrimary)
                Text("Every scene records with these unless it has its own.")
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.Color.textSecondary)
            }

            VStack(spacing: Theme.Spacing.sm) {
                sourceRow("Display", symbol: "display") { displayPicker }
                sourceRow("Camera", symbol: "web.camera") { cameraPicker }
                sourceRow("Microphone", symbol: "mic") { microphonePicker }
            }

            VStack(spacing: Theme.Spacing.sm) {
                toggleRow(
                    "System audio",
                    detail: "Capture what the Mac is playing.",
                    isOn: $draft.includeSystemAudio
                )
                clickLogToggle
            }

            PBDivider()
            applyButtons
        }
        .padding(Theme.Spacing.lg)
        .frame(width: 340)
        .onAppear { seedDraftIfMissing() }
    }

    // MARK: Rows

    /// Label + picker on one inset row. The picker drops its own label so the
    /// row's icon+title is the only caption.
    private func sourceRow<Content: View>(
        _ title: String,
        symbol: String,
        @ViewBuilder picker: () -> Content
    ) -> some View {
        HStack(spacing: Theme.Spacing.md) {
            Label(title, systemImage: symbol)
                .font(Theme.Font.body)
                .foregroundStyle(Theme.Color.textSecondary)
                .frame(width: 104, alignment: .leading)
            picker()
                .labelsHidden()
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .pbInsetRow()
    }

    private func toggleRow(_ title: String, detail: String, isOn: Binding<Bool>) -> some View {
        HStack(spacing: Theme.Spacing.md) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(Theme.Font.body)
                    .foregroundStyle(Theme.Color.textPrimary)
                Text(detail)
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.Color.textSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Toggle(title, isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        }
        .pbInsetRow()
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

    // MARK: Pickers

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
        return toggleRow(
            "Track cursor",
            detail: accessibilityGranted
                ? "Powers zoom-follow and auto-zoom in the editor."
                : "Requires Accessibility permission.",
            isOn: $draft.logClicks
        )
        .disabled(!accessibilityGranted)
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
