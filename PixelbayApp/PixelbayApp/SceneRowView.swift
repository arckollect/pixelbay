import AppKit
import Foundation
import PixelbayCore
import SwiftUI

// Phase 5 — one row in the Scenes window list. Mirrors the clip-row visual
// language from ProjectView (thumbnail left, content middle, actions right)
// so users moving between Scenes and the editor recognize the layout.
//
// Display-only for slice 5.5: the Record / Re-record button calls
// `model.recordScene(at:)`, which is a stub until slice 5.6 lands the
// actual RecordingService wiring. Description edits, source-override
// edits, drag-reorder, and active-take selection all work today.

struct SceneRowView: View {

    @Bindable var model: ScenesSessionModel
    let sceneIndex: Int
    let catalog: ScenesSourceCatalog

    @State private var draftDescription: String = ""
    @State private var showOverrideOptions: Bool = false
    @State private var confirmDeletePresented: Bool = false

    private var scene: PixelbayCore.Scene {
        guard model.session.scenes.indices.contains(sceneIndex) else { return PixelbayCore.Scene() }
        return model.session.scenes[sceneIndex]
    }

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            thumbnail
            VStack(alignment: .leading, spacing: 8) {
                header
                descriptionField
                if scene.takes.count > 1 {
                    takePicker
                }
                overrideDisclosure
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            actionColumn
        }
        .padding(12)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
        .onAppear {
            draftDescription = scene.description
        }
        // Re-sync the draft if the underlying scene changes from elsewhere
        // (e.g. persistence reload, reorder, undo).
        .onChange(of: scene.description) { _, newValue in
            if newValue != draftDescription {
                draftDescription = newValue
            }
        }
        .alert("Delete this scene?", isPresented: $confirmDeletePresented) {
            Button("Delete", role: .destructive) {
                model.deleteScene(at: sceneIndex)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            if scene.takes.isEmpty {
                Text("This scene has no recordings yet.")
            } else {
                Text("\(scene.takes.count) take\(scene.takes.count == 1 ? "" : "s") will be removed from the session. Underlying media files remain in the bundle until you run Clean up unused takes.")
            }
        }
    }

    // MARK: - Pieces

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("Scene \(sceneIndex + 1)")
                .font(.headline)
            if scene.sourceOverride.hasAnyOverride {
                Text("Custom")
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.tint.opacity(0.18), in: Capsule())
                    .foregroundStyle(.tint)
                    .accessibilityLabel("Uses custom source overrides")
            }
            Spacer()
            if let take = scene.activeTake {
                Text(durationLabel(take.durationSeconds))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var descriptionField: some View {
        TextField("Describe this scene…", text: $draftDescription, axis: .vertical)
            .textFieldStyle(.plain)
            .lineLimit(1...3)
            .font(.callout)
            // Persist on commit / focus loss to avoid keystroke-rate
            // writes (the model also debounces, but a per-character
            // update churns @Observable subscribers unnecessarily).
            .onSubmit {
                model.updateDescription(sceneID: scene.id, to: draftDescription)
            }
            .onChange(of: draftDescription) { _, newValue in
                model.updateDescription(sceneID: scene.id, to: newValue)
            }
    }

    private var takePicker: some View {
        // Pill-shaped segmented control: 1 / 2 / 3 / …
        Picker("Active take", selection: takeBinding) {
            ForEach(scene.takes.indices, id: \.self) { idx in
                Text("\(idx + 1)").tag(idx)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(maxWidth: 160, alignment: .leading)
    }

    private var takeBinding: Binding<Int> {
        Binding(
            get: { scene.activeTakeIndex ?? 0 },
            set: { newValue in
                model.setActiveTake(sceneID: scene.id, takeIndex: newValue)
            }
        )
    }

    private var overrideDisclosure: some View {
        DisclosureGroup("Custom sources", isExpanded: $showOverrideOptions) {
            SceneOverridePickers(
                catalog: catalog,
                defaults: model.session.defaults,
                override: overrideBinding
            )
            .padding(.top, 6)
        }
        .font(.caption)
        .controlSize(.small)
    }

    private var overrideBinding: Binding<SceneSourceOverride> {
        Binding(
            get: { scene.sourceOverride },
            set: { newValue in
                model.updateSourceOverride(sceneID: scene.id, newValue)
            }
        )
    }

    private var actionColumn: some View {
        VStack(spacing: 8) {
            recordButton
            Button(role: .destructive) {
                confirmDeletePresented = true
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("Delete this scene")
        }
        .frame(width: 110)
    }

    private var recordButton: some View {
        Button {
            Task { await model.recordScene(at: sceneIndex) }
        } label: {
            Label(scene.takes.isEmpty ? "Record" : "Re-record",
                  systemImage: scene.takes.isEmpty ? "record.circle.fill" : "arrow.clockwise.circle.fill")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .tint(scene.takes.isEmpty ? .red : .accentColor)
        .controlSize(.regular)
        .disabled(model.phase != .idle)
    }

    // MARK: - Thumbnail

    @ViewBuilder
    private var thumbnail: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(.background.tertiary)
            if let path = scene.activeTake?.thumbnailRelativePath,
               let nsImage = loadThumbnail(relativePath: path)
            {
                Image(nsImage: nsImage)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 56, height: 56)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                Image(systemName: "video.fill")
                    .imageScale(.large)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(width: 56, height: 56)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(.separator, lineWidth: 0.5)
        )
    }

    /// Loads `bundle/<relativePath>` via `NSImage(contentsOf:)`. Returns
    /// nil when the file's missing (recording-in-progress race, or a take
    /// from before slice 5.6 with no thumbnail yet). Cheap to call per
    /// render because NSImage caches recently-loaded URLs.
    private func loadThumbnail(relativePath: String) -> NSImage? {
        let url = model.bundle.url.appendingPathComponent(relativePath)
        return NSImage(contentsOf: url)
    }

    private func durationLabel(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let m = total / 60
        let s = total % 60
        return String(format: "%d:%02d", m, s)
    }
}

// MARK: - Per-scene source override pickers

private struct SceneOverridePickers: View {
    let catalog: ScenesSourceCatalog
    let defaults: ScenesGlobalDefaults
    @Binding var override: SceneSourceOverride

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            displayPicker
            cameraPicker
            microphonePicker
            systemAudioToggle
        }
    }

    private var displayPicker: some View {
        Picker("Display", selection: displayBinding) {
            Text("Use default")
                .tag(UInt32?.none)
            ForEach(catalog.displays) { display in
                Text(display.localizedName).tag(UInt32?.some(display.id))
            }
        }
        .pickerStyle(.menu)
    }

    private var displayBinding: Binding<UInt32?> {
        Binding(
            get: { override.displayID },
            set: { override.displayID = $0 }
        )
    }

    private var cameraPicker: some View {
        Picker("Camera", selection: cameraBinding) {
            Text("Use default").tag(String?.none)
            ForEach(catalog.cameras) { cam in
                Text(cam.localizedName).tag(String?.some(cam.id))
            }
        }
        .pickerStyle(.menu)
    }

    private var cameraBinding: Binding<String?> {
        Binding(
            get: { override.cameraUniqueID },
            set: { override.cameraUniqueID = $0 }
        )
    }

    private var microphonePicker: some View {
        Picker("Microphone", selection: micBinding) {
            Text("Use default").tag(String?.none)
            ForEach(catalog.microphones) { mic in
                Text(mic.localizedName).tag(String?.some(mic.id))
            }
        }
        .pickerStyle(.menu)
    }

    private var micBinding: Binding<String?> {
        Binding(
            get: { override.micUniqueID },
            set: { override.micUniqueID = $0 }
        )
    }

    private var systemAudioToggle: some View {
        // Tri-state toggle: Use default / On / Off. Picker is the simplest
        // SwiftUI control that surfaces the three states inline without a
        // custom view.
        Picker("System audio", selection: sysAudioBinding) {
            Text("Use default").tag(Bool?.none)
            Text("On").tag(Bool?.some(true))
            Text("Off").tag(Bool?.some(false))
        }
        .pickerStyle(.menu)
    }

    private var sysAudioBinding: Binding<Bool?> {
        Binding(
            get: { override.includeSystemAudio },
            set: { override.includeSystemAudio = $0 }
        )
    }
}
