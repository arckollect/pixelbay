import AppKit
import CoreMedia
import PixelbayCore
import PixelbayEditor
import PixelbayPlayback
import PixelbayTimelineUI
import SwiftUI

// Phase 2 Inspector-style edit scene. No timeline UI here — that's the
// PixelbayTimelineUI work, separate. This scene gives the user enough
// surface to verify the editor model end-to-end:
//   • Preview surface (PreviewPlayer) on the left
//   • Clip list + per-clip Inspector on the right
//   • Project name (editable, drives RenameProjectCommand)
//   • Per-clip volume + speed sliders (drive Set*Command with debounce)
//   • Undo / Redo / Save in the toolbar (Cmd-Z / ⇧Cmd-Z / Cmd-S)
//   • Reveal in Finder for the bundle URL
//
// The scene loads its own PreviewPlayer; PostCaptureView's player isn't
// reused because the previews diverge once the user starts editing.

struct ProjectView: View {
    @Bindable var document: ProjectDocument

    @State private var player = PreviewPlayer()
    @State private var selectedClipID: ClipID?
    @State private var selectedEffectKeyframeID: EffectKeyframeID?
    @State private var editingName: String = ""
    @FocusState private var isEditingName: Bool
    @State private var pixelsPerSecond: CGFloat = TimelineLayoutCalculator.defaultPixelsPerSecond
    @State private var trackHeight: CGFloat = TimelineLayoutCalculator.defaultTrackHeight
    /// Per-clip in-progress slider values. Non-nil while the user is
    /// dragging; consulted by the Inspector sliders so they show the
    /// live drag value instead of the (still-stale-until-drag-end)
    /// clip.volume / clip.speed. On drag end we submit ONE EditCommand
    /// with the final value and clear the preview. Without this, the
    /// undo stack would fill with hundreds of micro-edits per slider
    /// drag.
    @State private var previewVolumes: [ClipID: Double] = [:]
    @State private var previewSpeeds: [ClipID: Double] = [:]

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    previewPane
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    Divider()
                    timelinePane
                        .frame(minHeight: 280, maxHeight: 420)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                inspectorPane
                    .frame(width: 320)
            }
        }
        .frame(minWidth: 1000, minHeight: 700)
        // Note: focusedSceneValue(\.openProjectDocument, document) is set
        // by the enclosing ProjectWindow, not here — that way the document
        // is published once per scene from the natural owner.
        // Keyed on (bundleURL, revision) — revision is bumped per
        // apply/undo/redo (not save), so every committed edit rebuilds
        // the AVMutableComposition. Without this, trims/splits/volume
        // changes only show up in the timeline, not in playback. Save
        // doesn't bump revision (content unchanged) so the preview
        // doesn't reload then either.
        .task(id: ProjectViewKey(bundleURL: document.bundleURL, revision: document.revision)) {
            let cursorTrajectory = await CursorTrajectoryLoader.load(
                for: document.project,
                bundleURL: document.bundleURL
            )
            await player.load(
                project: document.project,
                bundleURL: document.bundleURL,
                wallpaperSource: .live,
                cursorTrajectory: cursorTrajectory
            )
            editingName = document.project.name
            if selectedClipID == nil {
                selectedClipID = document.project.tracks.flatMap(\.clips).first?.id
            }
        }
        .onChange(of: document.project.name) { _, newName in
            // Sync editingName when the project name changes externally
            // (load / undo / redo).
            if editingName != newName {
                editingName = newName
            }
        }
        .onDisappear {
            player.dispose()
        }
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 12) {
            // Toolbar Undo/Redo are visible affordances; the keyboard
            // shortcuts (⌘Z / ⇧⌘Z) live on the Edit menu via
            // EditUndoRedoCommands so a focused TextField doesn't shadow
            // them with text-undo.
            Button {
                Task { await document.undo() }
            } label: {
                Label("Undo", systemImage: "arrow.uturn.backward")
            }
            .disabled(!document.canUndo)
            .help(document.undoActionName.map { "Undo \($0)" } ?? "Undo")
            Button {
                Task { await document.redo() }
            } label: {
                Label("Redo", systemImage: "arrow.uturn.forward")
            }
            .disabled(!document.canRedo)
            .help(document.redoActionName.map { "Redo \($0)" } ?? "Redo")
            Divider().frame(height: 22)
            // Save shortcut lives on the File menu's SaveProjectCommand
            // (FocusedValue-bound), so this button is just an in-window
            // affordance that mirrors document state.
            Button {
                Task { await document.save() }
            } label: {
                Label(document.isDirty ? "Save (modified)" : "Save", systemImage: "tray.and.arrow.down")
            }
            .disabled(!document.isDirty || document.status == .saving)
            Spacer()
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([document.bundleURL])
            } label: {
                Label("Reveal", systemImage: "folder")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - Preview pane

    @ViewBuilder
    private var previewPane: some View {
        switch player.status {
        case .idle, .loading:
            VStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Loading preview…").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            VStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text("Preview unavailable: \(message)")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 40)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .ready:
            VStack(spacing: 8) {
                PreviewPlayerView(player: player)
                    .background(Color.black, in: RoundedRectangle(cornerRadius: 6))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                playbackControls
            }
            .padding(16)
        }
    }

    private var playbackControls: some View {
        HStack(spacing: 12) {
            Button {
                player.togglePlayPause()
            } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .frame(width: 22, height: 18)
            }
            .controlSize(.large)
            .keyboardShortcut(.space, modifiers: [])
            Text(formatTime(player.currentTime.seconds))
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 60, alignment: .trailing)
            Slider(
                value: Binding<Double>(
                    get: {
                        guard player.duration.seconds > 0 else { return 0 }
                        return player.currentTime.seconds / player.duration.seconds
                    },
                    set: { player.seekFraction($0) }
                ),
                in: 0...1
            )
            Text(formatTime(player.duration.seconds))
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 60, alignment: .leading)
        }
    }

    // MARK: - Timeline pane

    private var timelinePane: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("Timeline")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                Spacer()
                // Track-height (row size) control. Lets the user condense
                // tracks when the project has many of them (so they all
                // fit in the visible pane without vertical scrolling) or
                // expand to give waveforms more room.
                Image(systemName: "rectangle.compress.vertical")
                    .foregroundStyle(.secondary)
                    .help("Condense tracks")
                Slider(
                    value: $trackHeight,
                    in: TimelineLayoutCalculator.minTrackHeight...TimelineLayoutCalculator.maxTrackHeight
                )
                .frame(width: 110)
                .help("Adjust track row height")
                Image(systemName: "rectangle.expand.vertical")
                    .foregroundStyle(.secondary)
                    .help("Expand tracks")
                Divider().frame(height: 16)
                Image(systemName: "minus.magnifyingglass")
                    .foregroundStyle(.secondary)
                Slider(
                    value: $pixelsPerSecond,
                    in: TimelineLayoutCalculator.minPixelsPerSecond...TimelineLayoutCalculator.maxPixelsPerSecond
                )
                .frame(width: 140)
                .help("Zoom timeline")
                Image(systemName: "plus.magnifyingglass")
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            // TimelineView wraps an NSScrollView internally — no SwiftUI
            // ScrollView here. SwiftUI's ScrollView didn't agree with
            // `TimelineNSView.isFlipped` and parked the default scroll
            // position at the bottom of content (System Audio visible,
            // ruler hidden), then `defaultScrollAnchor(.topLeading)`
            // re-snapped on every playhead tick. The native NSScrollView
            // respects the flipped documentView and starts at the top.
            TimelineView(
                project: document.project,
                bundleURL: document.bundleURL,
                pixelsPerSecond: pixelsPerSecond,
                trackHeight: trackHeight,
                scrollX: 0,
                selectedClipID: selectedClipID,
                selectedEffectKeyframeID: selectedEffectKeyframeID,
                playheadTime: rationalTime(player.currentTime),
                revision: document.revision,
                onSelect: { selectedClipID = $0 },
                onSelectEffectKeyframe: { selectedEffectKeyframeID = $0 },
                onApplyCommand: { command in
                    Task { await document.apply(command) }
                },
                onScrub: { time in
                    let cmTime = CMTime(value: time.value, timescale: time.timescale)
                    player.seek(to: cmTime)
                }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.background.secondary)
        }
    }

    // MARK: - Inspector pane

    private var inspectorPane: some View {
        VStack(alignment: .leading, spacing: 16) {
            projectInspector
            Divider()
            layoutInspector
            Divider()
            effectsInspector
            Divider()
            tracksAndClipsList
            Divider()
            clipInspector
            Spacer(minLength: 0)
            if case .failed(let message) = document.status {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
                    Text(message).font(.callout)
                    Spacer()
                    Button("Dismiss") { document.acknowledgeError() }
                }
                .padding(8)
                .background(.red.opacity(0.10), in: RoundedRectangle(cornerRadius: 6))
            }
        }
        .padding(16)
    }

    private var projectInspector: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Project").font(.headline)
            HStack {
                TextField("Name", text: $editingName)
                    .textFieldStyle(.roundedBorder)
                    .focused($isEditingName)
                    .onSubmit { commitNameIfChanged() }
                    .onChange(of: isEditingName) { _, focused in
                        // Commit on focus-loss (clicking elsewhere, ⌘S,
                        // closing the project) — not just Enter. Fixes
                        // the "typed but didn't press Enter then clicked
                        // Save, lost the change" wart.
                        if !focused { commitNameIfChanged() }
                    }
            }
        }
    }

    private func commitNameIfChanged() {
        guard editingName != document.project.name else { return }
        Task { await document.apply(RenameProjectCommand(newName: editingName)) }
    }

    // MARK: - Layout inspector (Phase 3a)

    private var layoutInspector: some View {
        LayoutInspector(layout: document.project.layout) { newLayout in
            Task { await document.apply(SetLayoutPresetCommand(newLayout: newLayout)) }
        }
    }

    // MARK: - Effects inspector (Phase 3b)

    private var effectsInspector: some View {
        EffectsInspector(
            project: document.project,
            bundleURL: document.bundleURL,
            selectedKeyframeID: $selectedEffectKeyframeID,
            onApply: { command in
                Task { await document.apply(command) }
            },
            onSeek: { time in
                let cmTime = CMTime(value: time.value, timescale: time.timescale)
                player.seek(to: cmTime)
            }
        )
    }

    private var tracksAndClipsList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Clips").font(.headline)
            if document.project.tracks.flatMap(\.clips).isEmpty {
                Text("This project has no clips.")
                    .foregroundStyle(.secondary)
                    .font(.callout)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(document.project.tracks) { track in
                            Section {
                                ForEach(track.clips) { clip in
                                    clipRow(track: track, clip: clip)
                                }
                            } header: {
                                Text("\(track.name) (\(track.kind.rawValue))")
                                    .font(.caption.bold())
                                    .foregroundStyle(.secondary)
                                    .padding(.top, 4)
                            }
                        }
                    }
                }
                .frame(maxHeight: 220)
            }
        }
    }

    private func clipRow(track: Track, clip: Clip) -> some View {
        let isSelected = clip.id == selectedClipID
        return HStack(spacing: 8) {
            Image(systemName: clip.id == selectedClipID ? "play.circle.fill" : "play.circle")
                .foregroundStyle(isSelected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(HierarchicalShapeStyle.secondary))
            VStack(alignment: .leading, spacing: 0) {
                Text(clip.id.rawValue.prefix(8) + "…")
                    .font(.system(.caption, design: .monospaced))
                Text(formatRange(clip.timelineRange))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                Task { await document.apply(RemoveClipCommand(clipID: clip.id)) }
                if clip.id == selectedClipID { selectedClipID = nil }
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Remove clip")
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(isSelected ? Color.accentColor.opacity(0.18) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 4))
        .contentShape(Rectangle())
        .onTapGesture { selectedClipID = clip.id }
    }

    @ViewBuilder
    private var clipInspector: some View {
        if let clipID = selectedClipID, let clip = document.project.clip(clipID) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Clip").font(.headline)
                volumeSlider(for: clip)
                speedSlider(for: clip)
            }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Text("Clip").font(.headline)
                Text("Select a clip from the list to edit.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func volumeSlider(for clip: Clip) -> some View {
        // Live value: the in-progress drag preview if non-nil, else the
        // committed clip.volume. The displayed % readout follows the
        // preview too so the user sees what they're about to commit.
        let liveValue = previewVolumes[clip.id] ?? min(clip.volume, 2.0)
        let clipID = clip.id
        let committedValue = clip.volume
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Volume")
                Spacer()
                Text(String(format: "%.0f%%", liveValue * 100))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Slider(
                value: Binding<Double>(
                    get: { liveValue },
                    set: { newValue in previewVolumes[clipID] = newValue }
                ),
                in: 0...2,
                onEditingChanged: { isEditing in
                    guard !isEditing, let final = previewVolumes[clipID] else { return }
                    previewVolumes[clipID] = nil
                    if abs(final - committedValue) < 0.0001 { return }
                    Task { await document.apply(SetClipVolumeCommand(clipID: clipID, newVolume: final)) }
                }
            )
        }
    }

    private func speedSlider(for clip: Clip) -> some View {
        let liveValue = previewSpeeds[clip.id] ?? min(max(clip.speed, 0.25), 4.0)
        let clipID = clip.id
        let committedValue = clip.speed
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Speed")
                Spacer()
                Text(String(format: "%.2f×", liveValue))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Slider(
                value: Binding<Double>(
                    get: { liveValue },
                    set: { newValue in previewSpeeds[clipID] = newValue }
                ),
                in: 0.25...4.0,
                onEditingChanged: { isEditing in
                    guard !isEditing, let final = previewSpeeds[clipID] else { return }
                    previewSpeeds[clipID] = nil
                    if abs(final - committedValue) < 0.0001 { return }
                    Task { await document.apply(SetClipSpeedCommand(clipID: clipID, newSpeed: final)) }
                }
            )
        }
    }

    // MARK: - Helpers

    private func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    private func formatRange(_ range: TimeRange) -> String {
        let start = Double(range.start.value) / Double(range.start.timescale)
        let dur = Double(range.duration.value) / Double(range.duration.timescale)
        return String(format: "%.2fs · %.2fs", start, dur)
    }

    private func rationalTime(_ cmTime: CMTime) -> RationalTime? {
        guard cmTime.isValid, !cmTime.isIndefinite else { return nil }
        return RationalTime(value: cmTime.value, timescale: cmTime.timescale)
    }
}

/// Composite key for ProjectView's preview-rebuild .task. The bundleURL
/// alone changes only when a different project is opened; the revision
/// changes per committed edit (apply/undo/redo). SwiftUI fires the task
/// on any change to the key, so both transitions trigger a rebuild.
private struct ProjectViewKey: Hashable {
    let bundleURL: URL
    let revision: Int
}
