import AppKit
import CoreMedia
import PixelbayCompositor
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
    /// Backing string for the editable window title (navigationTitle binding).
    @State private var editingName: String = ""
    /// Debounce for titlebar-rename commits — see the editingName onChange.
    @State private var nameCommitTask: Task<Void, Never>?
    @State private var pixelsPerSecond: CGFloat = TimelineLayoutCalculator.defaultPixelsPerSecond
    /// Default row height ≈60% along the header slider's 24–96 range —
    /// tall rows so thumbnails and waveforms read clearly out of the box.
    /// The header slider still adjusts it live.
    @State private var trackHeight: CGFloat = 67
    /// Per-row height overrides (keyed by TimelineDisplayRow.id), set by
    /// dragging a row header's bottom edge in the timeline. View state —
    /// session-scoped, not persisted to the document. Moving the global
    /// track-height slider resets all rows to uniform.
    @State private var rowHeights: [String: CGFloat] = [:]
    /// Live width of the timeline pane, captured by a GeometryReader — the
    /// input to fit-to-width zoom.
    @State private var timelineWidth: CGFloat = 0
    /// False until the user touches the zoom slider. While false, the zoom
    /// auto-fits the whole project into the visible timeline width (and
    /// re-fits as the project or pane changes); the first manual zoom
    /// hands control to the user.
    @State private var userAdjustedZoom = false
    /// True while a header slider (track height / zoom) is mid-drag. The
    /// timeline suppresses its expensive content layers (thumbnails,
    /// waveforms) for the duration so per-tick rebuilds stay cheap.
    @State private var timelineSliderDragging = false
    /// Which inspector tab the right-rail is showing. Independent of clip /
    /// keyframe selection, except that selecting an effect keyframe in the
    /// timeline auto-switches here to `.zoom` (the only surface that edits
    /// it). The per-clip volume/speed drag-preview state now lives inside
    /// `AudioInspector`.
    @State private var selectedTab: InspectorTab = .layout
    /// Preview fit (letterbox) vs fill (crop). The editor defaults to fit so
    /// recorded UI is never cropped while inspecting detail.
    private let previewFill: Bool = false
    /// Editor preview sharpness. HD matches the UHD export render cap, then is
    /// clamped to the visible backing-pixel size so enlarging the viewer asks
    /// the compositor for a larger, crisper frame instead of stretching.
    private let previewQuality: PreviewPlayer.PreviewQuality = .hd
    /// Backing-pixel size of the visible video pane. OpenScreen renders its
    /// Pixi canvas at the viewport's DPR-scaled size; this gives Pixelbay's
    /// native preview the same moving target instead of stretching an older
    /// composition when the timeline is resized smaller.
    @State private var previewBackingSize: CGSize = .zero
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
    /// Live preview-rebuild state for an in-flight layer drag in the preview.
    /// A leading-edge throttle (see `previewLayoutLive`): the latest rects are
    /// stashed in `pendingLayoutRects` and drained through one `player.load`
    /// fast-path at a time (`liveLayoutInFlight`), rendering the footage
    /// continuously at ~`liveLayoutInterval` while the outline tracks the cursor
    /// 1:1. `liveLayoutGeneration` lets the mouse-up commit invalidate a render
    /// that's already past cancellation so it can't clobber the committed frame.
    @State private var liveLayoutTask: Task<Void, Never>?
    @State private var liveLayoutInFlight = false
    @State private var lastLayoutRenderAt: ContinuousClock.Instant?
    @State private var pendingLayoutRects: (screen: NormalizedRect, webcam: NormalizedRect?)?
    @State private var liveLayoutGeneration = 0
    /// Live-drag render cadence. The outline stays at 60 Hz; the footage
    /// re-renders at ~20 Hz, which reads as live under the tracking outline
    /// without thrashing the AVFoundation recompose path.
    private static let liveLayoutInterval: Duration = .milliseconds(50)

    var body: some View {
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
                .frame(width: 380)
        }
        .frame(minWidth: 1000, minHeight: 700)
        .background(Theme.Color.bgBase)
        .tint(Theme.Color.accent)
        // Native document chrome: the project name IS the window title,
        // editable inline via the titlebar (click the title → rename), and
        // the dirty state reads as the standard "Edited" subtitle. Toolbar
        // actions live in the unified titlebar toolbar (see editorToolbar)
        // instead of a custom in-window strip — native materials, native
        // spacing, native overflow behaviour.
        .navigationTitle($editingName)
        .navigationSubtitle(document.isDirty ? "Edited" : "")
        .toolbar { editorToolbar }
        // Note: focusedSceneValue(\.openProjectDocument, document) is set
        // by the enclosing ProjectWindow, not here — that way the document
        // is published once per scene from the natural owner.
        // Keyed on (bundleURL, revision) — revision is bumped per
        // apply/undo/redo (not save), so every committed edit rebuilds
        // the AVMutableComposition. Without this, trims/splits/volume
        // changes only show up in the timeline, not in playback. Save
        // doesn't bump revision (content unchanged) so the preview
        // doesn't reload then either.
        //
        // Preview RENDER SIZE is deliberately NOT in this key. It used to be
        // (quantized to 64px), so dragging the preview/timeline split re-keyed
        // the task and forced a full composition rebuild each time the backing
        // size crossed a 64px boundary — the reload flips status to .loading,
        // which swaps the live video for the spinner: visible flicker on every
        // resize. The build still reads `previewMaxOutputSize` live below, so
        // the FIRST build is correctly sized to the pane; we simply don't
        // rebuild on subsequent resizes. Growing the pane a lot scales the
        // existing high-res frame (imperceptibly soft for an editing preview);
        // the next real edit rebuilds at the current size.
        .task(id: ProjectViewKey(
            bundleURL: document.bundleURL,
            revision: document.revision,
            previewQuality: previewQuality
        )) {
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
                project: editorPreviewProject(from: document.project),
                bundleURL: document.bundleURL,
                wallpaperSource: .live,
                wallpaperImageProvider: .live(
                    bundleURL: document.bundleURL,
                    builtinURL: { WallpaperCatalog.url(forBuiltinID: $0) }
                ),
                cursorTrajectory: cursorData?.samples,
                cursorClickTimes: cursorData?.clickTimes ?? [],
                cursorSprite: SystemCursorSprite.make(),
                quality: previewQuality,
                maxOutputSize: previewMaxOutputSize
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
        .onChange(of: editingName) { _, _ in
            // The titlebar rename field writes through the navigationTitle
            // binding. Debounce before dispatching RenameProjectCommand so a
            // burst of binding writes coalesces into one undoable rename —
            // and the external-sync path above no-ops via the equality guard
            // in commitNameIfChanged.
            nameCommitTask?.cancel()
            nameCommitTask = Task {
                try? await Task.sleep(nanoseconds: 400_000_000)
                guard !Task.isCancelled else { return }
                commitNameIfChanged()
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

    /// Native unified-titlebar toolbar. Items render with the system's
    /// toolbar treatment (material, spacing, overflow menu on narrow
    /// windows) instead of the old custom in-window strip. Keyboard
    /// shortcuts stay on the menu bar (EditUndoRedoCommands /
    /// SaveProjectCommand) — these are the visible affordances.
    @ToolbarContentBuilder
    private var editorToolbar: some ToolbarContent {
        // "Scenes" is the add-content entry point, so it sits leading
        // (navigation position), apart from the document actions.
        ToolbarItem(placement: .navigation) {
            Button {
                scenesAppendTarget.set(document.bundleURL)
                openWindow(id: WindowID.scenes)
            } label: {
                Label("Scenes", systemImage: "rectangle.stack.badge.play")
            }
            .help("Add more scenes to this project")
        }
        ToolbarItemGroup {
            ControlGroup {
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
            }
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
            .help(allLanesCollapsed
                  ? "Expand every grouped lane to show underlying tracks"
                  : "Collapse every grouped lane into Video / Audio bands")
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([document.bundleURL])
            } label: {
                Label("Reveal in Finder", systemImage: "folder")
            }
            .help("Show the project bundle in Finder")
            Button {
                Task { await document.save() }
            } label: {
                Label("Save", systemImage: "tray.and.arrow.down")
            }
            .disabled(!document.isDirty || document.status == .saving)
            .help(document.isDirty ? "Save changes (⌘S)" : "All changes saved")
        }
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
        // The preview sits in a deep "canvas well" (bgDeep) so the footage
        // card visually floats above the editor chrome — the depth ladder
        // reads: canvas well < window chrome < raised controls.
        switch player.status {
        case .idle, .loading:
            VStack(spacing: Theme.Spacing.md) {
                ProgressView().controlSize(.small)
                Text("Loading preview…")
                    .font(Theme.Font.body)
                    .foregroundStyle(Theme.Color.textSecondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.Color.bgDeep)
        case .failed(let message):
            VStack(spacing: Theme.Spacing.md) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(Theme.Color.warning)
                Text("Preview unavailable")
                    .font(Theme.Font.cardTitle)
                    .foregroundStyle(Theme.Color.textPrimary)
                Text(message)
                    .font(Theme.Font.body)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Theme.Color.textSecondary)
                    .padding(.horizontal, 40)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.Color.bgDeep)
        case .ready:
            ZStack {
                PreviewPlayerView(
                    player: player,
                    fill: previewFill,
                    onBackingSizeChange: { size in
                        DispatchQueue.main.async {
                            guard abs(size.width - previewBackingSize.width) >= 2
                                || abs(size.height - previewBackingSize.height) >= 2 else { return }
                            previewBackingSize = size
                        }
                    }
                )
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
                // Free-form transform is available on every tab — moving/scaling
                // the screen or webcam isn't tied to which inspector is open.
                // (Only the Reset Layout affordance is Layout-tab-scoped, since
                // it lives in that tab's inspector.) Chrome shows only on
                // hover/selection, so it stays out of the way until used.
                if let overlay = transformOverlayData {
                    PreviewTransformOverlay(
                        screenRect: overlay.screen,
                        webcamRect: overlay.webcam,
                        outputSize: player.outputSize,
                        camShape: document.project.layout.camShape,
                        fill: previewFill,
                        onLivePreview: { screen, webcam in
                            previewLayoutLive(screen: screen, webcam: webcam)
                        },
                        onCommit: { screen, webcam in
                            commitCustomLayout(screen: screen, webcam: webcam)
                        }
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.large))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.large)
                    .strokeBorder(Theme.Color.borderSubtle, lineWidth: Theme.Stroke.hairline)
            )
            // Two-layer shadow: a tight contact shadow plus a soft ambient
            // falloff — the card reads as floating in the canvas well rather
            // than painted on it. CRITICAL: the shadows live on this
            // background shape, NOT on the card subtree itself. A `.shadow`
            // around the AppKit-hosted PreviewPlayerView forces the live
            // video layer through SwiftUI's shadow compositing, which
            // re-rasterizes on every body invalidation (tab switch) and
            // split-resize tick — visible as preview flicker.
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.large)
                    .fill(Theme.Color.bgBase)
                    .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
                    .shadow(color: .black.opacity(0.45), radius: 22, y: 10)
            )
            .padding(Theme.Spacing.lg)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.Color.bgDeep)
        }
    }

    /// Centered playback cluster — the single most used control in the
    /// editor, so it owns the middle of the timeline header (matching the
    /// native transport placement in QuickTime / FCP) instead of hiding
    /// at the left edge. Timecode lives separately at the header's leading
    /// edge (see timecodeReadout).
    private var timelineTransport: some View {
        HStack(spacing: Theme.Spacing.xs) {
            TransportButton(symbol: "backward.end.fill", help: "Jump to start") {
                player.seekToStart()
            }
            TransportButton(symbol: "backward.frame.fill", help: "Step back one frame") {
                player.stepFrame(by: -1)
            }
            TransportButton(
                symbol: player.isPlaying ? "pause.fill" : "play.fill",
                help: player.isPlaying ? "Pause" : "Play",
                prominent: true
            ) {
                player.togglePlayPause()
            }
            .keyboardShortcut(.space, modifiers: [])
            TransportButton(symbol: "forward.frame.fill", help: "Step forward one frame") {
                player.stepFrame(by: 1)
            }
            TransportButton(symbol: "forward.end.fill", help: "Jump to end") {
                player.seekToEnd()
            }
        }
        .padding(.horizontal, Theme.Spacing.xs)
        .padding(.vertical, 2)
        .background(Theme.Color.bgElevated, in: Capsule())
        .overlay(Capsule().strokeBorder(Theme.Color.borderSubtle, lineWidth: Theme.Stroke.hairline))
    }

    /// Current position (bright) over total duration (quiet) — promoted from
    /// the old cramped inline readout so scrubbing has a clear anchor.
    private var timecodeReadout: some View {
        HStack(spacing: 4) {
            Text(Timecode.clock(player.currentTime.seconds))
                .font(Theme.Font.monoTimecode)
                .foregroundStyle(Theme.Color.textPrimary)
            Text("/ \(Timecode.clock(player.duration.seconds))")
                .font(Theme.Font.monoTimecode)
                .foregroundStyle(Theme.Color.textTertiary)
        }
    }

    /// Trailing header cluster: view-density controls (track height, zoom)
    /// and the append-recording entry point.
    private var timelineViewTools: some View {
        HStack(spacing: Theme.Spacing.sm) {
            // Track-height (row size) control. Lets the user condense
            // tracks when the project has many of them (so they all
            // fit in the visible pane without vertical scrolling) or
            // expand to give waveforms more room.
            timelineGlyph("rectangle.compress.vertical", help: "Condense tracks")
            PBSlider(
                value: Binding(
                    get: { Double(trackHeight) },
                    set: {
                        trackHeight = CGFloat($0)
                        // The global slider is the "make everything uniform"
                        // control — clear per-row overrides so it visibly
                        // affects every lane again.
                        if !rowHeights.isEmpty { rowHeights = [:] }
                    }
                ),
                in: Double(TimelineLayoutCalculator.minTrackHeight)...Double(TimelineLayoutCalculator.maxTrackHeight),
                size: .mini,
                onEditingChanged: { timelineSliderDragging = $0 }
            )
            .frame(width: 88)
            .help("Adjust all track row heights (drag a row header's bottom edge to size one row)")
            timelineGlyph("rectangle.expand.vertical", help: "Expand tracks")
            PBDivider(.vertical).frame(height: 16)
            timelineGlyph("minus.magnifyingglass", help: "Zoom out")
            PBSlider(
                value: Binding(
                    get: { Double(pixelsPerSecond) },
                    set: {
                        pixelsPerSecond = CGFloat($0)
                        // First manual zoom ends the auto fit-to-width mode.
                        userAdjustedZoom = true
                    }
                ),
                in: Double(TimelineLayoutCalculator.minPixelsPerSecond)...Double(TimelineLayoutCalculator.maxPixelsPerSecond),
                size: .mini,
                onEditingChanged: { timelineSliderDragging = $0 }
            )
            .frame(width: 112)
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
            // Header layout: timecode anchored leading, transport truly
            // centered (ZStack, so it doesn't drift as the side content
            // changes width), view tools + Add anchored trailing.
            ZStack {
                HStack {
                    timecodeReadout
                    Spacer()
                }
                timelineTransport
                HStack(spacing: Theme.Spacing.sm) {
                    Spacer()
                    timelineViewTools
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
                rowHeightOverrides: rowHeights,
                suppressContent: timelineSliderDragging,
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
                },
                onRowHeightsChange: { rowHeights = $0 }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.Color.bgDeep)
            // Fit-to-width zoom: capture the pane's live width, and re-fit
            // whenever it (or the project) changes while the user hasn't
            // taken manual control of the zoom.
            .background(
                GeometryReader { geo in
                    Color.clear
                        .onAppear { timelineWidth = geo.size.width }
                        .onChange(of: geo.size.width) { _, newWidth in
                            timelineWidth = newWidth
                        }
                }
            )
            .onChange(of: timelineWidth) { _, _ in fitTimelineZoomIfNeeded() }
            .onChange(of: document.revision) { _, _ in fitTimelineZoomIfNeeded() }
        }
    }

    // MARK: - Inspector pane

    private var inspectorPane: some View {
        VStack(spacing: 0) {
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
        PBTabItem(tag: .layout, systemImage: "rectangle.on.rectangle", help: "Background & Scene", title: "Layout"),
        PBTabItem(tag: .camera, systemImage: "video", help: "Camera composition", title: "Camera"),
        PBTabItem(tag: .cursor, systemImage: "cursorarrow.rays", help: "Cursor appearance & motion", title: "Cursor"),
        PBTabItem(tag: .zoom, systemImage: "plus.magnifyingglass", help: "Zoom & Effects", title: "Effects"),
        PBTabItem(tag: .audio, systemImage: "speaker.wave.2", help: "Audio mix", title: "Audio")
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

    // MARK: - Layout inspector (Phase 3a) — background/scene

    /// True when the layout is a free-form custom arrangement (produced by
    /// dragging/scaling a layer in the preview).
    private var isCustomLayout: Bool {
        if case .custom = document.project.layout.mode { return true }
        return false
    }

    private func applyLayout(_ newLayout: LayoutPreset) {
        Task { await document.apply(SetLayoutPresetCommand(newLayout: newLayout)) }
    }

    /// The Layout tab: background/scene controls only. Camera composition lives
    /// in the dedicated Camera tab so both panes stay calmer and more scannable.
    private var layoutInspector: some View {
        BackgroundInspector(
            layout: document.project.layout,
            bundleURL: document.bundleURL,
            onChange: { applyLayout($0) },
            onError: { document.reportError($0) }
        )
    }

    // MARK: - Camera inspector

    private var cameraInspector: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
            CameraInspector(
                layout: document.project.layout,
                onChange: { applyLayout($0) }
            )
            if isCustomLayout {
                PBDivider()
                customLayoutResetRow
            }
        }
    }

    /// Shown at the bottom of the Camera tab while a custom arrangement is
    /// active. Resets the transform only — background / padding / corner radius
    /// are left as the user dialed them.
    private var customLayoutResetRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: Theme.Spacing.sm) {
                Image(systemName: "point.topleft.down.curvedto.point.bottomright.up")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.Color.accent)
                Text("Custom arrangement")
                    .font(Theme.Font.cardTitle)
                    .foregroundStyle(Theme.Color.textPrimary)
                Spacer()
            }
            Button {
                var next = document.project.layout
                next.mode = .pip(position: .bottomRight, size: .medium)
                applyLayout(next)
            } label: {
                Label("Reset Layout", systemImage: "arrow.uturn.backward")
            }
            .buttonStyle(.pbCompact)
        }
        .pbInsetRow()
    }

    // MARK: - Cursor inspector (Phase 3c)

    private var cursorInspector: some View {
        CursorInspector(
            cursorSettings: document.project.cursorSettings,
            tuningSettings: document.project.tuning,
            onCursorChange: { newCursor in
                Task { await document.apply(SetCursorSettingsCommand(newSettings: newCursor)) }
            },
            onTuningChange: { newTuning in
                Task { await document.apply(SetTuningSettingsCommand(newSettings: newTuning)) }
            },
            onTuningPreview: { tuning in
                handleTuningPreview(tuning)
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
            playheadTime: player.currentTime.seconds,
            selectedKeyframeID: $selectedEffectKeyframeID,
            onApply: { command in
                Task { await document.apply(command) }
            },
            onSeek: { time in
                let cmTime = CMTime(value: time.value, timescale: time.timescale)
                player.seek(to: cmTime)
            },
            onFollowSafeZonePreview: { fraction in
                zoomFollowSafeZoneOverlayFraction = fraction
            },
            onTuningPreview: { tuning in
                handleTuningPreview(tuning)
            }
        )
    }

    // MARK: - Helpers

    private func handleTuningPreview(_ tuning: TuningSettings?) {
        liveTuningTask?.cancel()
        guard let tuning else { return }  // release → committed reload takes over
        liveTuningTask = Task {
            // ~100 ms coalescing: drag ticks arrive at display rate; re-solving
            // the camera path + swapping the videoComposition at ~10 Hz tracks
            // the finger closely without churning AVFoundation.
            try? await Task.sleep(nanoseconds: 100_000_000)
            guard !Task.isCancelled else { return }
            var previewProject = document.project
            previewProject.tuning = tuning
            previewProject = editorPreviewProject(from: previewProject)
            // Structure (tracks/clips/assets) is unchanged, so PreviewPlayer's
            // fast path rebuilds ONLY the videoComposition against the existing
            // player item — no decoder churn while scrubbing a slider.
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
                cursorSprite: SystemCursorSprite.make(),
                quality: previewQuality,
                maxOutputSize: previewMaxOutputSize
            )
        }
    }

    private func rationalTime(_ cmTime: CMTime) -> RationalTime? {
        guard cmTime.isValid, !cmTime.isIndefinite else { return nil }
        return RationalTime(value: cmTime.value, timescale: cmTime.timescale)
    }

    /// Fit-to-width zoom: choose pixelsPerSecond so the whole project spans
    /// the visible lane width — a 10-second take and a 5-minute session both
    /// open fully visible. Re-applied on pane resize and on every committed
    /// edit (append/trim changes the duration) until the user takes manual
    /// control of the zoom slider, after which their choice sticks.
    private func fitTimelineZoomIfNeeded() {
        guard !userAdjustedZoom else { return }
        // Trailing margin keeps the project's tail off the hard right edge.
        let laneWidth = timelineWidth - TimelineLayoutCalculator.trackHeaderWidth - 24
        guard laneWidth > 100 else { return }
        let totalSeconds = TimelineLayoutCalculator.totalSeconds(in: document.project)
        guard totalSeconds > 0.1 else { return }
        let fit = laneWidth / totalSeconds
        let clamped = min(
            max(fit, TimelineLayoutCalculator.minPixelsPerSecond),
            TimelineLayoutCalculator.maxPixelsPerSecond
        )
        if abs(clamped - pixelsPerSecond) > 0.01 {
            pixelsPerSecond = clamped
        }
    }

    private var previewMaxOutputSize: CGSize {
        guard previewBackingSize.width >= 2, previewBackingSize.height >= 2 else {
            return previewQuality.maxOutputSize
        }
        let maxSize = previewQuality.maxOutputSize
        return CGSize(
            width: max(2, min(maxSize.width, previewBackingSize.width)),
            height: max(2, min(maxSize.height, previewBackingSize.height))
        )
    }

    private func editorPreviewProject(from project: Project) -> Project {
        var previewProject = project
        // The editor is an inspection surface: temporal blur makes paused and
        // scrubbed frames look soft, especially when the preview is enlarged.
        // Keep the authored blur settings in the document/export path, but
        // render the live editor preview crisp.
        previewProject.tuning.blurStrength = 0
        previewProject.tuning.cursorBlur = 0
        return previewProject
    }

    // MARK: - Interactive transform

    /// Whether the project has a webcam layer to transform — mirrors the
    /// `hasWebcam` predicate `PreviewComposition` uses (a webcam track with
    /// clips).
    private var projectHasWebcam: Bool {
        document.project.tracks.contains { $0.kind == .webcam && !$0.clips.isEmpty }
    }

    /// Current resolved screen / webcam rects in normalized output space, for
    /// the transform overlay to draw and hit-test. nil until the player reports
    /// a real output size.
    private var transformOverlayData: (screen: NormalizedRect, webcam: NormalizedRect?)? {
        let outputSize = player.outputSize
        guard outputSize.width > 0, outputSize.height > 0 else { return nil }
        let resolved = LayoutCalculator.resolve(
            preset: document.project.layout,
            outputSize: outputSize,
            hasWebcam: projectHasWebcam
        )
        return (
            normalizedRect(resolved.screen, outputSize: outputSize),
            resolved.webcam.map { normalizedRect($0, outputSize: outputSize) }
        )
    }

    private func normalizedRect(_ r: LayerRect, outputSize: CGSize) -> NormalizedRect {
        NormalizedRect(
            x: Double(r.minX / outputSize.width),
            y: Double(r.minY / outputSize.height),
            width: Double(r.size.width / outputSize.width),
            height: Double(r.size.height / outputSize.height)
        )
    }

    /// Build a `.custom` layout from dragged rects, applying the
    /// auto-default-background rule: shrinking the screen over no background
    /// would expose black, so seed a tasteful wallpaper + rounded corners (the
    /// existing "floating" look) when that happens.
    private func customLayout(screen: NormalizedRect, webcam: NormalizedRect?) -> LayoutPreset {
        var next = document.project.layout
        next.mode = .custom(screen: screen, webcam: webcam)
        if !screen.fillsOutput, case .none = next.background {
            if let wallpaper = BackgroundInspector.wallpaperPresets.first {
                next.background = .wallpaper(wallpaper)
            } else {
                next.background = .solid(color: PixelbayCore.RGBColor(r: 0.10, g: 0.11, b: 0.14))
            }
            if next.screenCornerRadius == 0 { next.screenCornerRadius = 24 }
        }
        return next
    }

    /// Live rebuild of just the videoComposition while a layer is being dragged,
    /// so the footage moves/scales continuously instead of snapping on release.
    ///
    /// Leading-edge throttle: the latest rects are always stashed; if a render
    /// is in flight it drains them when it finishes, otherwise we render
    /// immediately (if a full interval has elapsed) or schedule one trailing
    /// render at the interval boundary. A continuous drag produces a steady
    /// ~`liveLayoutInterval` stream of renders AND the final position always
    /// renders (it's the last value stashed). Structure is unchanged so
    /// PreviewPlayer takes the videoComposition fast path.
    private func previewLayoutLive(screen: NormalizedRect, webcam: NormalizedRect?) {
        pendingLayoutRects = (screen, webcam)

        // At most one render in flight; it re-checks the stash and drains.
        guard !liveLayoutInFlight else { return }

        let now = ContinuousClock.now
        if let last = lastLayoutRenderAt, now - last < Self.liveLayoutInterval {
            // Too soon for a leading render: schedule a single trailing render
            // at the interval boundary (replacing any already scheduled one).
            let wait = Self.liveLayoutInterval - (now - last)
            liveLayoutTask?.cancel()
            liveLayoutTask = Task { @MainActor in
                try? await Task.sleep(for: wait)
                guard !Task.isCancelled else { return }
                await runLiveLayoutRender()
            }
        } else {
            // Leading edge: render now.
            liveLayoutTask?.cancel()
            liveLayoutTask = Task { @MainActor in await runLiveLayoutRender() }
        }
    }

    /// Drains `pendingLayoutRects` through the `player.load` fast path one render
    /// at a time, looping to catch ticks that arrived mid-render (so the final
    /// drag position always lands). A monotonic generation guard drops a render
    /// that a commit invalidated while it was past cancellation.
    @MainActor
    private func runLiveLayoutRender() async {
        guard !liveLayoutInFlight else { return }
        liveLayoutInFlight = true
        defer { liveLayoutInFlight = false }

        while let rects = pendingLayoutRects {
            pendingLayoutRects = nil
            lastLayoutRenderAt = ContinuousClock.now
            let gen = liveLayoutGeneration

            var previewProject = document.project
            previewProject.layout = customLayout(screen: rects.screen, webcam: rects.webcam)
            previewProject = editorPreviewProject(from: previewProject)
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
                cursorSprite: SystemCursorSprite.make(),
                quality: previewQuality,
                maxOutputSize: previewMaxOutputSize
            )

            // A commit landed while this render was in flight — let its
            // revision-keyed reload own the final frame; don't clobber it.
            guard gen == liveLayoutGeneration else { return }
        }
    }

    /// Commit a dragged/nudged layout as one undoable edit. The revision bump
    /// re-keys the debounced preview reload, which renders the final state.
    private func commitCustomLayout(screen: NormalizedRect, webcam: NormalizedRect?) {
        // Stop the live throttle: cancel any scheduled render, clear the stash
        // so the drain loop ends, and bump the generation so an in-flight render
        // that's already past cancellation discards itself.
        liveLayoutTask?.cancel()
        pendingLayoutRects = nil
        liveLayoutGeneration += 1
        let newLayout = customLayout(screen: screen, webcam: webcam)
        Task { await document.apply(SetLayoutPresetCommand(newLayout: newLayout)) }
    }
}

/// Transport control: a quiet glyph that lifts to a circular wash on hover.
/// `prominent` marks the play/pause action — larger glyph, always-bright.
private struct TransportButton: View {
    let symbol: String
    let help: String
    var prominent: Bool = false
    let action: () -> Void

    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: prominent ? 14 : 11, weight: .semibold))
                .foregroundStyle(
                    prominent || hovered ? Theme.Color.textPrimary : Theme.Color.textSecondary
                )
                .frame(width: prominent ? 34 : 26, height: 26)
                .background(Circle().fill(hovered ? Color.white.opacity(0.08) : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .animation(.easeOut(duration: 0.12), value: hovered)
        .onHover { hovered = $0 }
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
///
/// Preview render size is intentionally absent — see the `.task(id:)` note
/// in `body` for why (resize flicker). The build reads the live backing
/// size instead.
private struct ProjectViewKey: Hashable {
    let bundleURL: URL
    let revision: Int
    let previewQuality: PreviewPlayer.PreviewQuality
}

/// The right-rail inspector categories, surfaced as a vertical icon-tab rail.
enum InspectorTab: Hashable {
    /// "Background & Scene" — backdrop gallery + frame padding/corner radius.
    case layout
    /// "Camera" — webcam composition: mode, position, size, split, and shape.
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
    var minTopHeight: CGFloat = 360
    /// Minimum height for the `bottom` pane (the timeline floor).
    var minBottomHeight: CGFloat = 132
    @ViewBuilder var top: () -> Top
    @ViewBuilder var bottom: () -> Bottom

    /// Default split: sized so the standard collapsed timeline (transport
    /// header + ruler + Video / Audio / Effects rows at the 67pt default
    /// track height) is fully visible with room to breathe below the
    /// effects lane; the preview takes the rest without dominating.
    @State private var bottomHeight: CGFloat = 250
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
