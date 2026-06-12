import AppKit
import CoreMedia
import PixelbayCore
import PixelbayDesignSystem
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
    @Environment(ScenesAppendTarget.self) private var scenesAppendTarget
    @Environment(\.openWindow) private var openWindow

    @State private var player = PreviewPlayer()
    @State private var selectedClipID: ClipID?
    @State private var selectedEffectKeyframeID: EffectKeyframeID?
    @State private var editingName: String = ""
    @FocusState private var isEditingName: Bool
    @State private var pixelsPerSecond: CGFloat = TimelineLayoutCalculator.defaultPixelsPerSecond
    @State private var trackHeight: CGFloat = TimelineLayoutCalculator.defaultTrackHeight
    /// Which inspector tab the right-rail is showing. Independent of clip /
    /// keyframe selection, except that selecting an effect keyframe in the
    /// timeline auto-switches here to `.zoom` (the only surface that edits
    /// it). The per-clip volume/speed drag-preview state now lives inside
    /// `AudioInspector`.
    @State private var selectedTab: InspectorTab = .layout
    /// Preview fit (letterbox) vs fill (crop). Toggled from the transport's
    /// aspect button; defaults to fit so nothing is cropped on open.
    @State private var previewFill: Bool = false
    /// Slice A.3 — controls the timeline-end "+" popover. Hosting the
    /// popover state here (rather than inside TimelineView) keeps the
    /// invasive change off `TimelineView.swift` so the parallel Branch B
    /// can keep restructuring timeline row rendering without conflict.
    @State private var appendPopoverPresented: Bool = false
    @State private var zoomFollowSafeZoneOverlayFraction: Double?
    /// Live Motion Tuning drag preview. The master cursor data is cached by
    /// the main reload task so each drag tick can re-solve the camera path +
    /// rebuild the videoComposition without re-reading the clicks sidecar
    /// from disk; the in-flight task is replaced on every tick (≈10 Hz after
    /// the debounce) and the mouse-up commit takes over via the normal
    /// revision-keyed reload.
    @State private var cachedCursorData: CursorTrajectoryLoader.CursorData?
    @State private var liveTuningTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            PBDivider()
            HStack(spacing: 0) {
                // The resizable preview/timeline split owns its own drag
                // state (inside ResizableVSplit) — deliberately NOT hoisted
                // to ProjectView. If `timelineHeight` lived here, every
                // drag tick (~120/s) would invalidate this whole body
                // (toolbar + both inspectors + transport), dropping frames
                // and making BOTH panes stutter. Isolated, the drag only
                // re-evaluates the split subtree.
                ResizableVSplit {
                    previewPane
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } bottom: {
                    timelinePane
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                PBDivider(.vertical)
                inspectorPane
                    .frame(width: 360)
            }
        }
        .frame(minWidth: 1000, minHeight: 700)
        .background(Theme.Color.bgBase)
        .tint(Theme.Color.accent)
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
            // Debounce preview rebuilds. Every committed edit bumps `revision`
            // and re-keys this task; rapid edits — e.g. clicking through the
            // background-swatch gallery — would otherwise spawn a fresh
            // AVPlayerItem + custom compositor each time. That churn floods the
            // log with transient decoder errors (`missingScreenLayer`, VRP
            // -12852, CustomVideoCompositor -12784) and can exhaust
            // VideoToolbox decode sessions. Sleeping first lets a burst
            // coalesce: SwiftUI cancels this task when the next edit arrives,
            // so only the settled state actually reloads. ~140 ms is below
            // perceptible preview latency for a single edit.
            do {
                try await Task.sleep(nanoseconds: 140_000_000)
            } catch {
                return  // superseded by a newer edit
            }
            let cursorData = await CursorTrajectoryLoader.load(
                for: document.project,
                bundleURL: document.bundleURL
            )
            guard !Task.isCancelled else { return }
            cachedCursorData = cursorData
            await player.load(
                project: document.project,
                bundleURL: document.bundleURL,
                wallpaperSource: .live,
                wallpaperImageProvider: .live(
                    bundleURL: document.bundleURL,
                    builtinURL: { WallpaperCatalog.url(forBuiltinID: $0) }
                ),
                cursorTrajectory: cursorData?.samples,
                cursorClickTimes: cursorData?.clickTimes ?? [],
                cursorSprite: SystemCursorSprite.make()
            )
            guard !Task.isCancelled else { return }
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
        .onChange(of: document.revision) { _, _ in
            reconcileSelections()
        }
        .onDisappear {
            player.dispose()
        }
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: Theme.Spacing.sm) {
            // Slice A.2 — "Scenes" entry point. Sets the shared
            // ScenesAppendTarget singleton to this document's bundleURL,
            // then opens the singleton scenes window. The window snapshots
            // the URL on appear; the editor toolbar button stays the FIRST
            // item in the HStack so Branch B's later additions (Expand /
            // Collapse all) at the END of the row don't conflict on merge.
            Button {
                scenesAppendTarget.set(document.bundleURL)
                openWindow(id: WindowID.scenes)
            } label: {
                Label("Scenes", systemImage: "rectangle.stack.badge.play")
            }
            .buttonStyle(.pbCompact)
            .help("Add more scenes to this project")
            PBDivider(.vertical).frame(height: 20)
            // Toolbar Undo/Redo are visible affordances; the keyboard
            // shortcuts (⌘Z / ⇧⌘Z) live on the Edit menu via
            // EditUndoRedoCommands so a focused TextField doesn't shadow
            // them with text-undo.
            Button {
                Task { await document.undo() }
            } label: {
                Label("Undo", systemImage: "arrow.uturn.backward")
            }
            .buttonStyle(.pbCompact)
            .disabled(!document.canUndo)
            .help(document.undoActionName.map { "Undo \($0)" } ?? "Undo")
            Button {
                Task { await document.redo() }
            } label: {
                Label("Redo", systemImage: "arrow.uturn.forward")
            }
            .buttonStyle(.pbCompact)
            .disabled(!document.canRedo)
            .help(document.redoActionName.map { "Redo \($0)" } ?? "Redo")
            PBDivider(.vertical).frame(height: 20)
            // Save shortcut lives on the File menu's SaveProjectCommand
            // (FocusedValue-bound), so this button is just an in-window
            // affordance that mirrors document state.
            Button {
                Task { await document.save() }
            } label: {
                Label(document.isDirty ? "Save (modified)" : "Save", systemImage: "tray.and.arrow.down")
            }
            .buttonStyle(.pbPrimary)
            .disabled(!document.isDirty || document.status == .saving)
            Spacer()
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([document.bundleURL])
            } label: {
                Label("Reveal", systemImage: "folder")
            }
            .buttonStyle(.pbCompact)
            PBDivider(.vertical).frame(height: 20)
            // Branch B (Slice B.4) — bulk toggle of every grouped lane.
            // Reads the smart-default seed to decide which direction the
            // button toggles to. INSERTION ORDER: this is the LAST item
            // in the toolbar HStack so the merge surface against Branch
            // A's "Scenes" button (added as the FIRST item) stays
            // minimal (one diff per edge, no body interleave).
            Button {
                let nowCollapsed = !allLanesCollapsed
                Task {
                    await document.apply(SetAllLanesCollapsedCommand(collapsed: nowCollapsed))
                }
            } label: {
                Label(
                    allLanesCollapsed ? "Expand All" : "Collapse All",
                    systemImage: allLanesCollapsed
                        ? "chevron.down.square"
                        : "chevron.right.square"
                )
            }
            .buttonStyle(.pbCompact)
            .help(allLanesCollapsed
                  ? "Expand every grouped lane to show underlying tracks"
                  : "Collapse every grouped lane into Video / Audio bands")
        }
        .padding(.horizontal, Theme.Spacing.lg)
        .padding(.vertical, Theme.Spacing.sm)
        .background(Theme.Color.bgDeep)
    }

    /// True when every known lane group is currently collapsed (per the
    /// resolved state — explicit value falls back to the smart-default
    /// seed). Drives the toolbar button's label + glyph.
    private var allLanesCollapsed: Bool {
        LaneGroupID.allCases.allSatisfy { document.project.isLaneCollapsed($0) }
    }

    // MARK: - Preview pane

    @ViewBuilder
    private var previewPane: some View {
        switch player.status {
        case .idle, .loading:
            VStack(spacing: Theme.Spacing.sm) {
                ProgressView().controlSize(.small)
                Text("Loading preview…")
                    .font(Theme.Font.body)
                    .foregroundStyle(Theme.Color.textSecondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.Color.bgBase)
        case .failed(let message):
            VStack(spacing: Theme.Spacing.sm) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.Color.warning)
                Text("Preview unavailable: \(message)")
                    .font(Theme.Font.body)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Theme.Color.textSecondary)
                    .padding(.horizontal, 40)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.Color.bgBase)
        case .ready:
            VStack(spacing: Theme.Spacing.sm) {
                ZStack {
                    PreviewPlayerView(player: player, fill: previewFill)
                    if let fraction = zoomFollowSafeZoneOverlayFraction {
                        ZoomFollowSafeZoneOverlay(
                            fraction: fraction,
                            videoSize: player.outputSize,
                            fill: previewFill,
                            color: .blue
                        )
                        .allowsHitTesting(false)
                        .transition(.opacity)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.Color.bgBase, in: RoundedRectangle(cornerRadius: Theme.Radius.medium))
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.medium))
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.medium)
                        .strokeBorder(Theme.Color.borderSubtle, lineWidth: Theme.Stroke.hairline)
                )
                transportBar
            }
            .padding(Theme.Spacing.lg)
        }
    }

    // Industry-standard transport: a clean control strip BELOW the viewer
    // (not glass floating over the footage — that read as choppy and blended
    // into the video). Transport cluster · current/total timecode · scrubber
    // · fit-fill toggle.
    private var transportBar: some View {
        HStack(spacing: Theme.Spacing.md) {
            HStack(spacing: Theme.Spacing.xs) {
                transportButton("backward.end.fill", help: "Jump to start") { player.seekToStart() }
                transportButton("backward.frame.fill", help: "Step back one frame") { player.stepFrame(by: -1) }
                Button {
                    player.togglePlayPause()
                } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.Color.textPrimary)
                        .frame(width: 32, height: 32)
                        .background(Theme.Color.bgElevated, in: Circle())
                        .overlay(Circle().strokeBorder(Theme.Color.borderSubtle, lineWidth: Theme.Stroke.hairline))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.space, modifiers: [])
                .help(player.isPlaying ? "Pause" : "Play")
                transportButton("forward.frame.fill", help: "Step forward one frame") { player.stepFrame(by: 1) }
                transportButton("forward.end.fill", help: "Jump to end") { player.seekToEnd() }
            }

            Text(Timecode.clock(player.currentTime.seconds))
                .font(Theme.Font.monoTimecode)
                .foregroundStyle(Theme.Color.textPrimary)
                .frame(width: 44, alignment: .trailing)
            PBSlider(
                value: Binding<Double>(
                    get: {
                        guard player.duration.seconds > 0 else { return 0 }
                        return player.currentTime.seconds / player.duration.seconds
                    },
                    set: { player.seekFraction($0) }
                ),
                in: 0...1,
                size: .mini
            )
            Text(Timecode.clock(player.duration.seconds))
                .font(Theme.Font.monoTimecode)
                .foregroundStyle(Theme.Color.textSecondary)
                .frame(width: 44, alignment: .leading)

            Button {
                previewFill.toggle()
            } label: {
                Image(systemName: previewFill
                      ? "rectangle.arrowtriangle.2.inward"
                      : "rectangle.arrowtriangle.2.outward")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.Color.textSecondary)
                    .frame(width: 26, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(previewFill ? "Fit (letterbox)" : "Fill (crop)")
        }
        .frame(height: 40)
    }

    private func transportButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.Color.textSecondary)
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    // MARK: - Timeline pane

    private func timelineGlyph(_ symbol: String, help: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(Theme.Color.textSecondary)
            .help(help)
    }

    private var timelinePane: some View {
        VStack(spacing: 0) {
            HStack(spacing: Theme.Spacing.sm) {
                Text("Timeline")
                    .font(Theme.Font.cardTitle)
                    .foregroundStyle(Theme.Color.textSecondary)
                Spacer()
                // Track-height (row size) control. Lets the user condense
                // tracks when the project has many of them (so they all
                // fit in the visible pane without vertical scrolling) or
                // expand to give waveforms more room.
                timelineGlyph("rectangle.compress.vertical", help: "Condense tracks")
                PBSlider(
                    value: Binding(get: { Double(trackHeight) }, set: { trackHeight = CGFloat($0) }),
                    in: Double(TimelineLayoutCalculator.minTrackHeight)...Double(TimelineLayoutCalculator.maxTrackHeight),
                    size: .mini
                )
                .frame(width: 96)
                .help("Adjust track row height")
                timelineGlyph("rectangle.expand.vertical", help: "Expand tracks")
                PBDivider(.vertical).frame(height: 16)
                timelineGlyph("minus.magnifyingglass", help: "Zoom out")
                PBSlider(
                    value: Binding(get: { Double(pixelsPerSecond) }, set: { pixelsPerSecond = CGFloat($0) }),
                    in: Double(TimelineLayoutCalculator.minPixelsPerSecond)...Double(TimelineLayoutCalculator.maxPixelsPerSecond),
                    size: .mini
                )
                .frame(width: 120)
                .help("Zoom timeline")
                timelineGlyph("plus.magnifyingglass", help: "Zoom in")
                PBDivider(.vertical).frame(height: 16)
                // Slice A.3 — "+" entry point for a single-shot append
                // recording. Anchored at the right edge of the timeline
                // header so the user reads it as "add to the end of this
                // timeline". The popover hosts source pickers; on stop the
                // result flows through `document.appendRecordingToTimeline`
                // which dispatches one InsertClipCommand per asset (undo-able).
                Button {
                    appendPopoverPresented = true
                } label: {
                    Label("Add", systemImage: "plus.circle.fill")
                }
                .buttonStyle(.pbCompact)
                .help("Record more — appends to the timeline tail")
                .popover(isPresented: $appendPopoverPresented, arrowEdge: .top) {
                    AppendRecordingPopover(
                        bundle: ProjectBundle(url: document.bundleURL),
                        onRecorded: { result in
                            Task { await document.appendRecordingToTimeline(result: result) }
                        }
                    )
                }
            }
            .padding(.horizontal, Theme.Spacing.md)
            .padding(.vertical, Theme.Spacing.xs)
            .background(Theme.Color.bgDeep)
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
                onSelectEffectKeyframe: { keyframeID in
                    selectedEffectKeyframeID = keyframeID
                    // Selecting a keyframe in the timeline reveals the only
                    // surface that edits it.
                    if keyframeID != nil { selectedTab = .zoom }
                },
                onApplyCommand: { command in
                    Task { await document.apply(command) }
                },
                onScrub: { time in
                    let cmTime = CMTime(value: time.value, timescale: time.timescale)
                    player.seek(to: cmTime)
                }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.Color.bgDeep)
        }
    }

    // MARK: - Inspector pane

    private var inspectorPane: some View {
        VStack(spacing: 0) {
            projectHeader
            PBDivider()
            PBVerticalTabRail(tabs: Self.inspectorTabs, selection: $selectedTab) { tab in
                ScrollView {
                    VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                        tabContent(tab)
                    }
                    .padding(Theme.Spacing.lg)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            if case .failed(let message) = document.status {
                PBDivider()
                errorBanner(message)
            }
        }
        .frame(maxHeight: .infinity)
        .background(Theme.Color.bgDeep)
    }

    private static let inspectorTabs: [PBTabItem<InspectorTab>] = [
        PBTabItem(tag: .layout, systemImage: "rectangle.on.rectangle", help: "Background & Scene"),
        PBTabItem(tag: .camera, systemImage: "video", help: "Camera"),
        PBTabItem(tag: .cursor, systemImage: "cursorarrow.rays", help: "Cursor"),
        PBTabItem(tag: .zoom, systemImage: "plus.magnifyingglass", help: "Zoom & Effects"),
        PBTabItem(tag: .audio, systemImage: "speaker.wave.2", help: "Audio")
    ]

    @ViewBuilder
    private func tabContent(_ tab: InspectorTab) -> some View {
        switch tab {
        case .layout: layoutInspector
        case .camera: cameraInspector
        case .cursor: cursorInspector
        case .zoom: effectsInspector
        case .audio: audioInspector
        }
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: Theme.Spacing.sm) {
            Image(systemName: "xmark.octagon.fill").foregroundStyle(Theme.Color.danger)
            Text(message).font(Theme.Font.body).foregroundStyle(Theme.Color.textPrimary)
            Spacer()
            Button("Dismiss") { document.acknowledgeError() }
                .buttonStyle(.pbGhost)
        }
        .padding(Theme.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.Color.danger.opacity(0.12))
    }

    private var projectHeader: some View {
        HStack(spacing: Theme.Spacing.sm) {
            TextField("Project Name", text: $editingName)
                .focused($isEditingName)
                .onSubmit { commitNameIfChanged() }
                .onChange(of: isEditingName) { _, focused in
                    // Commit on focus-loss (clicking elsewhere, ⌘S,
                    // closing the project) — not just Enter. Fixes
                    // the "typed but didn't press Enter then clicked
                    // Save, lost the change" wart.
                    if !focused { commitNameIfChanged() }
                }
                .pbField(focused: isEditingName)
        }
        .padding(.horizontal, Theme.Spacing.lg)
        .padding(.vertical, Theme.Spacing.md)
    }

    private func commitNameIfChanged() {
        guard editingName != document.project.name else { return }
        Task { await document.apply(RenameProjectCommand(newName: editingName)) }
    }

    private func reconcileSelections() {
        let clips = document.project.tracks.flatMap(\.clips)
        let clipIDs = Set(clips.map(\.id))
        if let selectedClipID, !clipIDs.contains(selectedClipID) {
            self.selectedClipID = clips.first?.id
        } else if selectedClipID == nil {
            selectedClipID = clips.first?.id
        }

        let keyframeIDs = Set(document.project.effects.map(\.id))
        if let selectedEffectKeyframeID, !keyframeIDs.contains(selectedEffectKeyframeID) {
            self.selectedEffectKeyframeID = nil
        }
    }

    // MARK: - Background & Scene inspector (Phase 3a)

    private var layoutInspector: some View {
        BackgroundInspector(
            layout: document.project.layout,
            bundleURL: document.bundleURL,
            onChange: { newLayout in
                Task { await document.apply(SetLayoutPresetCommand(newLayout: newLayout)) }
            },
            onError: { message in
                document.reportError(message)
            }
        )
    }

    // MARK: - Camera inspector

    private var cameraInspector: some View {
        CameraInspector(
            layout: document.project.layout,
            onChange: { newLayout in
                Task { await document.apply(SetLayoutPresetCommand(newLayout: newLayout)) }
            }
        )
    }

    // MARK: - Cursor inspector (Phase 3c)

    private var cursorInspector: some View {
        CursorInspector(
            cursorSettings: document.project.cursorSettings,
            onCursorChange: { newCursor in
                Task { await document.apply(SetCursorSettingsCommand(newSettings: newCursor)) }
            }
        )
    }

    // MARK: - Audio inspector

    private var audioInspector: some View {
        AudioInspector(
            clip: selectedClipID.flatMap { document.project.clip($0) },
            audioTracks: document.project.tracks.filter { $0.kind.isAudioBearing },
            onApply: { command in
                Task { await document.apply(command) }
            }
        )
    }

    // MARK: - Effects inspector (Phase 3b)

    private var effectsInspector: some View {
        EffectsInspector(
            project: document.project,
            bundleURL: document.bundleURL,
            cursorSettings: document.project.cursorSettings,
            playheadTime: player.currentTime.seconds,
            selectedKeyframeID: $selectedEffectKeyframeID,
            onApply: { command in
                Task { await document.apply(command) }
            },
            onCursorChange: { newCursor in
                Task { await document.apply(SetCursorSettingsCommand(newSettings: newCursor)) }
            },
            onSeek: { time in
                let cmTime = CMTime(value: time.value, timescale: time.timescale)
                player.seek(to: cmTime)
            },
            onFollowSafeZonePreview: { fraction in
                zoomFollowSafeZoneOverlayFraction = fraction
            },
            onTuningPreview: { tuning in
                liveTuningTask?.cancel()
                guard let tuning else { return }  // release → committed reload takes over
                liveTuningTask = Task {
                    // ~100 ms coalescing: drag ticks arrive at display rate;
                    // re-solving the camera path + swapping the
                    // videoComposition at ~10 Hz tracks the finger closely
                    // without churning AVFoundation.
                    try? await Task.sleep(nanoseconds: 100_000_000)
                    guard !Task.isCancelled else { return }
                    var previewProject = document.project
                    previewProject.tuning = tuning
                    // Structure (tracks/clips/assets) is unchanged, so
                    // PreviewPlayer's fast path rebuilds ONLY the
                    // videoComposition against the existing player item —
                    // no decoder churn while scrubbing a slider.
                    await player.load(
                        project: previewProject,
                        bundleURL: document.bundleURL,
                        wallpaperSource: .live,
                        wallpaperImageProvider: .live(
                            bundleURL: document.bundleURL,
                            builtinURL: { WallpaperCatalog.url(forBuiltinID: $0) }
                        ),
                        cursorTrajectory: cachedCursorData?.samples,
                        cursorClickTimes: cachedCursorData?.clickTimes ?? [],
                        cursorSprite: SystemCursorSprite.make()
                    )
                }
            }
        )
    }

    // MARK: - Helpers

    private func rationalTime(_ cmTime: CMTime) -> RationalTime? {
        guard cmTime.isValid, !cmTime.isIndefinite else { return nil }
        return RationalTime(value: cmTime.value, timescale: cmTime.timescale)
    }
}

private struct ZoomFollowSafeZoneOverlay: View {
    let fraction: Double
    let videoSize: CGSize
    let fill: Bool
    let color: Color

    var body: some View {
        GeometryReader { geo in
            let videoRect = fittedVideoRect(container: geo.size)
            let safeFraction = CGFloat(min(max(fraction, 0.01), 1.0))
            let safeSize = CGSize(
                width: videoRect.width * safeFraction,
                height: videoRect.height * safeFraction
            )
            let safeRect = CGRect(
                x: videoRect.midX - safeSize.width / 2,
                y: videoRect.midY - safeSize.height / 2,
                width: safeSize.width,
                height: safeSize.height
            )
            ZStack {
                Rectangle()
                    .fill(color.opacity(0.10))
                    .frame(width: safeRect.width, height: safeRect.height)
                    .position(x: safeRect.midX, y: safeRect.midY)
                Rectangle()
                    .stroke(color.opacity(0.82), lineWidth: 2)
                    .frame(width: safeRect.width, height: safeRect.height)
                    .position(x: safeRect.midX, y: safeRect.midY)
                Rectangle()
                    .stroke(color.opacity(0.28), style: StrokeStyle(lineWidth: 1, dash: [6, 5]))
                    .frame(width: videoRect.width, height: videoRect.height)
                    .position(x: videoRect.midX, y: videoRect.midY)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }

    private func fittedVideoRect(container: CGSize) -> CGRect {
        guard container.width > 0, container.height > 0,
              videoSize.width > 0, videoSize.height > 0 else {
            return CGRect(origin: .zero, size: container)
        }
        let containerAspect = container.width / container.height
        let videoAspect = videoSize.width / videoSize.height
        let width: CGFloat
        let height: CGFloat
        if fill {
            if containerAspect > videoAspect {
                width = container.width
                height = container.width / videoAspect
            } else {
                height = container.height
                width = container.height * videoAspect
            }
        } else {
            if containerAspect > videoAspect {
                height = container.height
                width = container.height * videoAspect
            } else {
                width = container.width
                height = container.width / videoAspect
            }
        }
        return CGRect(
            x: (container.width - width) / 2,
            y: (container.height - height) / 2,
            width: width,
            height: height
        )
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

/// The right-rail inspector categories, surfaced as a vertical icon-tab rail.
enum InspectorTab: Hashable {
    /// "Background & Scene" — background gallery + frame padding.
    case layout
    /// Webcam composition: PiP/side-by-side mode, position, size, shape.
    case camera
    case cursor
    case zoom
    case audio
}

/// A vertically-resizable two-pane split: `top` fills the remaining space,
/// `bottom` is the user-sized pane, with a draggable grabber between them.
///
/// **Why this is its own view (load-bearing for smoothness):** the drag
/// state (`bottomHeight` etc.) lives HERE, not on the parent editor. A
/// divider drag fires ~120 state updates/second; if that state sat on
/// `ProjectView`, each tick would invalidate the entire editor body
/// (toolbar, both inspector tabs, transport) and drop frames — the
/// "both panes look choppy" symptom. Scoped to this subtree, a drag only
/// re-evaluates the two panes that actually resize. The `top`/`bottom`
/// view-builders are captured from the parent's last body pass and simply
/// re-invoked here; rebuilding their (cheap) SwiftUI view values per tick
/// is fine — the embedded AppKit views guard their own `updateNSView`.
struct ResizableVSplit<Top: View, Bottom: View>: View {
    /// Minimum height reserved for the `top` pane (the preview never
    /// shrinks below this, even when the window is short).
    var minTopHeight: CGFloat = 240
    /// Minimum height for the `bottom` pane (the timeline floor).
    var minBottomHeight: CGFloat = 160
    @ViewBuilder var top: () -> Top
    @ViewBuilder var bottom: () -> Bottom

    @State private var bottomHeight: CGFloat = 320
    /// Bottom height captured at the start of a resize drag; nil when idle.
    @State private var dragStartHeight: CGFloat?
    /// Hover state for the grabber (drives the cursor + accent).
    @State private var handleHovered = false

    var body: some View {
        GeometryReader { geo in
            VStack(spacing: 0) {
                top()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                handle(containerHeight: geo.size.height)
                bottom()
                    .frame(height: clamped(geo.size.height))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Clamps the stored bottom height to the space available so a window
    /// resize never lets the bottom pane crowd out the top one.
    private func clamped(_ containerHeight: CGFloat) -> CGFloat {
        let maxH = max(minBottomHeight, containerHeight - minTopHeight)
        return min(maxH, max(minBottomHeight, bottomHeight))
    }

    /// Draggable divider. Drag DOWN to shrink the bottom pane (the top
    /// grows to fill); drag UP to grow it.
    private func handle(containerHeight: CGFloat) -> some View {
        ZStack {
            PBDivider()
            RoundedRectangle(cornerRadius: 2)
                .fill(handleHovered ? Theme.Color.textTertiary : Theme.Color.borderStrong)
                .frame(width: 40, height: 4)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 11)
        .background(Theme.Color.bgDeep)
        .contentShape(Rectangle())
        .onHover { hovering in
            handleHovered = hovering
            if hovering { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
        }
        .gesture(
            // CRITICAL: `.global` coordinate space, not the default `.local`.
            // The handle moves as a *result* of its own drag (growing the
            // bottom pane pushes the handle up). In `.local` space that
            // self-movement feeds straight back into `translation.height`,
            // so the layout oscillates between two states — the preview and
            // timeline visibly snap small↔big and scrollers flash in/out.
            // `.global` measures the drag against the window, which is
            // stable regardless of how the handle is repositioned, so the
            // resize tracks the cursor 1:1 and stays smooth.
            DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { value in
                    // Capture the on-screen (clamped) height at drag start so
                    // the first tick can't jump if the stored value was out of
                    // range for the current window size.
                    let start = dragStartHeight ?? clamped(containerHeight)
                    if dragStartHeight == nil { dragStartHeight = start }
                    let maxH = max(minBottomHeight, containerHeight - minTopHeight)
                    // Positive translation.height = dragging down → smaller bottom.
                    bottomHeight = min(maxH, max(minBottomHeight, start - value.translation.height))
                }
                .onEnded { _ in dragStartHeight = nil }
        )
    }
}
