import AppKit
import OSLog
import PixelbayCore
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
                    .frame(minWidth: 760, minHeight: 720)
            case .failed(let message):
                failureView(message)
                    .frame(minWidth: 760, minHeight: 720)
            case .ready(let model):
                readyView(model: model)
            }
        }
        .task {
            await loadModel()
            await catalog.reload()
        }
    }

    // MARK: - Loaded state

    @ViewBuilder
    private func readyView(model: ScenesSessionModel) -> some View {
        if case .recordingScene(let sceneIndex, let startedAt) = model.phase {
            // Compact HUD — the window's .windowResizability(.contentSize)
            // animates the frame down to the compact size while the
            // recording is live. Stop is wired through RecordingService
            // (existing HUD + ⌃⌘. hotkey both work); a button here gives
            // an additional surface if the user is looking at the
            // collapsed window.
            recordingHUDBody(
                model: model,
                sceneIndex: sceneIndex,
                startedAt: startedAt
            )
        } else {
            fullBody(model: model)
        }
    }

    private func fullBody(model: ScenesSessionModel) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            defaultsCard(model: model)
                .padding(.horizontal, 20)
                .padding(.top, 16)
            historySection(model: model)
            sceneList(model: model)
            bottomBar(model: model)
        }
        .frame(minWidth: 760, minHeight: 720)
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
                Text("Empty scenes will be skipped. The new scenes will append to the existing project timeline; this scenes session resets to three fresh rows.")
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
                HStack(spacing: 6) {
                    Image(systemName: "clock.arrow.circlepath")
                        .foregroundStyle(.secondary)
                    Text("History (\(model.historyRows.count) merged \(model.historyRows.count == 1 ? "scene" : "scenes"))")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
        }
    }

    private func recordingHUDBody(
        model: ScenesSessionModel,
        sceneIndex: Int,
        startedAt: Date
    ) -> some View {
        // Compact one-line state per decision #8. The window-frame collapse
        // happens because of `.windowResizability(.contentSize)` on the
        // Window declaration plus the smaller `.frame(...)` applied here.
        HStack(spacing: 14) {
            Image(systemName: "record.circle.fill")
                .foregroundStyle(.red)
                .imageScale(.large)
            VStack(alignment: .leading, spacing: 2) {
                Text("Recording Scene \(sceneIndex + 1)")
                    .font(.headline)
                TimelineView(.periodic(from: startedAt, by: 0.1)) { context in
                    Text(elapsedLabel(context.date.timeIntervalSince(startedAt)))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 12)
            Button("Stop") {
                Task { await recording.stop() }
            }
            .controlSize(.large)
            .keyboardShortcut(.return, modifiers: [])
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .frame(width: 320, height: 64)
    }

    private func elapsedLabel(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        let m = total / 60
        let s = total % 60
        return String(format: "Elapsed %d:%02d", m, s)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Scene Recording")
                .font(.largeTitle.bold())
            Text("Record one scene at a time. Re-record to add another take. Merge stitches the active takes into a normal Pixelbay project.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 20)
        .padding(.top, 24)
    }

    @ViewBuilder
    private func defaultsCard(model: ScenesSessionModel) -> some View {
        DefaultsBlock(model: model, catalog: catalog, permissions: permissions)
            .padding(16)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
    }

    private func sceneList(model: ScenesSessionModel) -> some View {
        // `List` + `.onMove` for drag-reorder. We strip the default chrome
        // (background, separators) so each row reads as a card rather than
        // a system list row.
        List {
            ForEach(model.session.scenes.indices, id: \.self) { idx in
                SceneRowView(model: model, sceneIndex: idx, catalog: catalog)
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 6, leading: 20, bottom: 6, trailing: 20))
            }
            .onMove { indices, destination in
                guard let source = indices.first else { return }
                model.moveScene(from: source, to: destination)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    private func bottomBar(model: ScenesSessionModel) -> some View {
        HStack {
            Button {
                model.addScene()
            } label: {
                Label("Add Scene", systemImage: "plus")
            }
            .controlSize(.large)

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

            Spacer()

            Button {
                mergeSkippedSceneCount = model.session.scenes.count - mergedSceneCount(in: model)
                mergeConfirmationPresented = true
            } label: {
                Label("Merge", systemImage: "rectangle.stack.fill")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!hasAnyRecordedTake(model: model))
        }
        .padding(20)
        .background(.background.tertiary)
    }

    private func hasDiscardedTakes(model: ScenesSessionModel) -> Bool {
        model.session.scenes.contains { $0.takes.count > 1 }
    }

    // MARK: - Loading / failure

    private var loadingView: some View {
        VStack(spacing: 14) {
            ProgressView()
            Text("Opening scenes bundle…")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func failureView(_ message: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 36))
                .foregroundStyle(.orange)
            Text("Couldn't open scenes bundle")
                .font(.title3.bold())
            Text(message)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            Button("Retry") {
                Task { await loadModel() }
            }
            .controlSize(.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Helpers

    @MainActor
    private func loadModel() async {
        modelState = .loading
        // Slice A.2 — snapshot the singleton's URL up-front so the rest of
        // this load runs against a frozen value. Clear the singleton
        // immediately AFTER the snapshot so a future window-open (e.g. the
        // launcher's "Scene Recording" button) that didn't go through the
        // editor's Scenes button never re-inherits this URL. Without this
        // clear, the target was sticky across window dismissals and a
        // user who closed their editor without saving would see their next
        // launcher-initiated scenes session silently append-merge into the
        // discarded project instead of producing a fresh one.
        let targetURL = scenesAppendTarget.bundleURL
        scenesAppendTarget.set(nil)
        do {
            let model: ScenesSessionModel
            if let targetURL {
                let document = try await ProjectDocument.open(bundleURL: targetURL)
                model = try await ScenesSessionModel.openForAppendingTo(
                    document: document,
                    recording: recording
                )
            } else {
                model = try await ScenesSessionModel.openOrCreatePersistent(recording: recording)
            }
            modelState = .ready(model)
        } catch {
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
    @Bindable var model: ScenesSessionModel
    let catalog: ScenesSourceCatalog
    let permissions: PermissionViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Default sources for new scenes")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            displayPicker
            cameraPicker
            microphonePicker
            Toggle("Capture system audio", isOn: includeSystemAudioBinding)
            clickLogToggle
        }
        .onAppear { seedDefaultsIfMissing() }
    }

    private var displayPicker: some View {
        Picker("Display", selection: displayBinding) {
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
        Picker("Camera", selection: cameraBinding) {
            Text("None").tag(String?.none)
            ForEach(catalog.cameras) { cam in
                Text(cam.localizedName).tag(String?.some(cam.id))
            }
        }
        .pickerStyle(.menu)
    }

    private var microphonePicker: some View {
        Picker("Microphone", selection: micBinding) {
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
            Toggle("Log mouse clicks for auto-zoom", isOn: logClicksBinding)
                .disabled(!accessibilityGranted)
            if !accessibilityGranted {
                Text("Requires Accessibility permission.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // Bindings — write back through the model's update API so the debounce
    // fires on every change (rather than mutating the @Observable field
    // in-place and skipping persistence).

    private var displayBinding: Binding<UInt32?> {
        Binding(
            get: { model.session.defaults.displayID },
            set: { newValue in
                var d = model.session.defaults
                d.displayID = newValue
                model.updateDefaults(d)
            }
        )
    }

    private var cameraBinding: Binding<String?> {
        Binding(
            get: { model.session.defaults.cameraUniqueID },
            set: { newValue in
                var d = model.session.defaults
                d.cameraUniqueID = newValue
                model.updateDefaults(d)
            }
        )
    }

    private var micBinding: Binding<String?> {
        Binding(
            get: { model.session.defaults.micUniqueID },
            set: { newValue in
                var d = model.session.defaults
                d.micUniqueID = newValue
                model.updateDefaults(d)
            }
        )
    }

    private var includeSystemAudioBinding: Binding<Bool> {
        Binding(
            get: { model.session.defaults.includeSystemAudio },
            set: { newValue in
                var d = model.session.defaults
                d.includeSystemAudio = newValue
                model.updateDefaults(d)
            }
        )
    }

    private var logClicksBinding: Binding<Bool> {
        Binding(
            get: { model.session.defaults.logClicks },
            set: { newValue in
                var d = model.session.defaults
                d.logClicks = newValue
                model.updateDefaults(d)
            }
        )
    }

    private func seedDefaultsIfMissing() {
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
}


