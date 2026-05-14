#if canImport(AppKit) && canImport(SwiftUI)
import AppKit
import OSLog
import PixelbayCore
import PixelbayEditor
import SwiftUI

private let log = Logger(subsystem: "com.pixelbay.PixelbayApp", category: "TimelineView")

// SwiftUI host for the AppKit-backed timeline. Per HANDOFF §5: the track
// area is an NSView (CALayer-backed) because SwiftUI 5's gesture / scroll
// / redraw still struggles with fine-grained scrubbing and simultaneous
// multi-clip drag at high zoom. The chrome (toolbar / inspector / media
// tab) stays in SwiftUI.
//
// Phase 2 v0.1 supports: read-only visualization, click-to-select, and
// drag interactions for Move + Trim (one EditCommand per drag — see
// `TimelineDragPreview`). Option-click split, waveforms, and playhead
// sync are subsequent slices.

public struct TimelineView: NSViewRepresentable {
    public let project: Project
    public var bundleURL: URL?
    public var pixelsPerSecond: CGFloat
    public var trackHeight: CGFloat
    public var scrollX: CGFloat
    public var selectedClipID: ClipID?
    public var selectedEffectKeyframeID: EffectKeyframeID?
    /// Cheap identity for the project. Bumped by the host on every
    /// committed edit (apply / undo / redo) — paired with the simple
    /// inputs above it forms a "did anything that needs a rebuild
    /// change?" check so the NSView can skip the full layer rebuild
    /// when only the playhead moved (~30fps). Without this, every
    /// PreviewPlayer time-observer tick rebuilds every CALayer.
    public var revision: Int
    /// Player playhead position in timeline-domain seconds. nil hides the
    /// overlay (e.g. before the player loads). Updated frequently during
    /// playback (~30fps via PreviewPlayer's periodic time observer); the
    /// NSView fast-paths the playhead-only update so we don't rebuild
    /// every CALayer per frame.
    public var playheadTime: RationalTime?
    public var onSelect: (ClipID?) -> Void
    public var onSelectEffectKeyframe: (EffectKeyframeID?) -> Void
    /// Posted on mouseUp at the end of a drag — the host (`ProjectView`)
    /// dispatches it through `ProjectDocument.apply(_:)`. Pure value type
    /// so it crosses the SwiftUI / AppKit boundary cleanly.
    public var onApplyCommand: (any EditCommand) -> Void
    /// Called on ruler click + drag with the timeline-domain time at the
    /// pointer. Host (ProjectView) seeks the PreviewPlayer.
    public var onScrub: (RationalTime) -> Void

    public init(
        project: Project,
        bundleURL: URL? = nil,
        pixelsPerSecond: CGFloat = TimelineLayoutCalculator.defaultPixelsPerSecond,
        trackHeight: CGFloat = TimelineLayoutCalculator.defaultTrackHeight,
        scrollX: CGFloat = 0,
        selectedClipID: ClipID?,
        selectedEffectKeyframeID: EffectKeyframeID? = nil,
        playheadTime: RationalTime? = nil,
        revision: Int = 0,
        onSelect: @escaping (ClipID?) -> Void,
        onSelectEffectKeyframe: @escaping (EffectKeyframeID?) -> Void = { _ in },
        onApplyCommand: @escaping (any EditCommand) -> Void = { _ in },
        onScrub: @escaping (RationalTime) -> Void = { _ in }
    ) {
        self.project = project
        self.bundleURL = bundleURL
        self.pixelsPerSecond = pixelsPerSecond
        self.trackHeight = trackHeight
        self.scrollX = scrollX
        self.selectedClipID = selectedClipID
        self.selectedEffectKeyframeID = selectedEffectKeyframeID
        self.playheadTime = playheadTime
        self.revision = revision
        self.onSelect = onSelect
        self.onSelectEffectKeyframe = onSelectEffectKeyframe
        self.onApplyCommand = onApplyCommand
        self.onScrub = onScrub
    }

    // We wrap our NSView in an NSScrollView (not SwiftUI's ScrollView)
    // because:
    //   1. SwiftUI's ScrollView fights `TimelineNSView.isFlipped = true`.
    //      With a flipped NSView under SwiftUI's ScrollView, the
    //      ScrollView's anchor lands on the bottom of our content (the
    //      last track) instead of the top (the ruler) — and worse,
    //      `defaultScrollAnchor(.topLeading)` keeps re-snapping the user
    //      back there on every PreviewPlayer time-observer tick.
    //   2. NSScrollView respects `documentView.isFlipped`: scroll origin
    //      (0,0) is the top-left of content, the ruler is visible by
    //      default, and there's no SwiftUI re-anchor running on each
    //      frame. AppKit also handles trackpad / scroll-wheel
    //      ergonomics natively.
    //   3. Enables the sticky-ruler `addFloatingSubview(_:for: .vertical)`
    //      machinery below — the ruler stays pinned to the top of the
    //      viewport during vertical scroll while still tracking
    //      horizontal scroll (so tick / clip alignment holds at every
    //      scroll position).
    public func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        // Match the flipped documentView so AppKit places (0,0) at top.
        scroll.contentView = FlippedClipView()
        let timeline = TimelineNSView()
        timeline.onSelect = onSelect
        timeline.onSelectEffectKeyframe = onSelectEffectKeyframe
        timeline.onApplyCommand = onApplyCommand
        timeline.onScrub = onScrub
        timeline.update(project: project, bundleURL: bundleURL, pixelsPerSecond: pixelsPerSecond, trackHeight: trackHeight, scrollX: scrollX, selectedClipID: selectedClipID, selectedEffectKeyframeID: selectedEffectKeyframeID, revision: revision)
        timeline.setPlayhead(time: playheadTime)
        scroll.documentView = timeline
        context.coordinator.timeline = timeline

        // Sticky ruler. Floating subview pinned vertically to the top
        // of the viewport; AppKit scrolls it horizontally with the
        // document content so tick positions match clip frames. Hosts
        // the playhead-head pentagon too — keeping the head in the
        // ruler means it stays visible even when the user scrolls down
        // through long track lists.
        let rulerHost = StickyRulerView()
        rulerHost.pixelsPerSecond = pixelsPerSecond
        rulerHost.playheadTime = playheadTime
        rulerHost.onScrub = onScrub
        scroll.addFloatingSubview(rulerHost, for: .vertical)
        context.coordinator.rulerHost = rulerHost

        sizeDocumentView(timeline, in: scroll, rulerHost: rulerHost)
        return scroll
    }

    public func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let timeline = scroll.documentView as? TimelineNSView else { return }
        timeline.onSelect = onSelect
        timeline.onSelectEffectKeyframe = onSelectEffectKeyframe
        timeline.onApplyCommand = onApplyCommand
        timeline.onScrub = onScrub
        timeline.update(project: project, bundleURL: bundleURL, pixelsPerSecond: pixelsPerSecond, trackHeight: trackHeight, scrollX: scrollX, selectedClipID: selectedClipID, selectedEffectKeyframeID: selectedEffectKeyframeID, revision: revision)
        timeline.setPlayhead(time: playheadTime)
        let rulerHost = context.coordinator.rulerHost
        rulerHost?.pixelsPerSecond = pixelsPerSecond
        rulerHost?.playheadTime = playheadTime
        rulerHost?.onScrub = onScrub
        sizeDocumentView(timeline, in: scroll, rulerHost: rulerHost)
    }

    public func makeCoordinator() -> Coordinator { Coordinator() }

    public final class Coordinator {
        // Weak so we don't fight AppKit's view-lifetime ownership; the
        // NSScrollView retains the floating subview, the documentView
        // retains the timeline.
        weak var timeline: TimelineNSView?
        weak var rulerHost: StickyRulerView?
    }

    /// Resize the documentView to the natural content size, with a floor
    /// of the visible viewport so the lanes always span the full width
    /// and don't leave a stripe of empty scroll-view background on the
    /// right when the project is short. Also sizes the floating ruler
    /// to match the document width so its ticks span the full content
    /// (AppKit clips to the viewport at draw time).
    private func sizeDocumentView(_ timeline: TimelineNSView, in scroll: NSScrollView, rulerHost: StickyRulerView?) {
        let natural = TimelineLayoutCalculator.contentSize(
            for: project,
            pixelsPerSecond: pixelsPerSecond,
            trackHeight: trackHeight
        )
        let viewport = scroll.contentSize
        let target = NSSize(
            width: max(natural.width, viewport.width),
            height: max(natural.height, viewport.height)
        )
        if timeline.frame.size != target {
            timeline.setFrameSize(target)
        }
        if let rulerHost {
            let rulerFrame = NSRect(
                x: 0, y: 0,
                width: target.width,
                height: TimelineLayoutCalculator.rulerHeight
            )
            if rulerHost.frame != rulerFrame {
                rulerHost.frame = rulerFrame
            }
        }
    }
}

/// NSClipView subclass that flips its coordinate system to match the
/// documentView. Without this, NSScrollView's clipView is non-flipped
/// and the documentView's flipped layout would render upside-down
/// relative to scroll position. AppKit's standard idiom for flipped
/// scrolling is `documentView.isFlipped == clipView.isFlipped`.
private final class FlippedClipView: NSClipView {
    override var isFlipped: Bool { true }
}

// CALayer-backed NSView. CAlayer hierarchy is rebuilt on every full
// `update(...)` for simplicity; during a drag we call a faster path
// that re-applies the drag preview without rebuilding from scratch.
// The playhead overlay has its own dedicated layer (`playheadLayer`)
// so per-frame playback updates only move that one layer rather than
// rebuild the whole tree.
public final class TimelineNSView: NSView {
    public var onSelect: ((ClipID?) -> Void)?
    public var onSelectEffectKeyframe: ((EffectKeyframeID?) -> Void)?
    public var onApplyCommand: ((any EditCommand) -> Void)?
    public var onScrub: ((RationalTime) -> Void)?

    private var project: Project?
    private var bundleURL: URL?
    private var pixelsPerSecond: CGFloat = TimelineLayoutCalculator.defaultPixelsPerSecond
    private var trackHeight: CGFloat = TimelineLayoutCalculator.defaultTrackHeight
    private var scrollX: CGFloat = 0
    private var selectedClipID: ClipID?
    private var selectedEffectKeyframeID: EffectKeyframeID?
    private var playheadTime: RationalTime?
    /// Last-applied non-playhead inputs. Compared against incoming `update(...)`
    /// calls to short-circuit no-op rebuilds. nil = first call (always rebuild).
    private var lastInputs: InputSnapshot?
    private let waveformLoader = WaveformLoader()

    private struct InputSnapshot: Equatable {
        let bundleURL: URL?
        let pixelsPerSecond: CGFloat
        let trackHeight: CGFloat
        let scrollX: CGFloat
        let selectedClipID: ClipID?
        let selectedEffectKeyframeID: EffectKeyframeID?
        let revision: Int
    }

    /// Cached layout — recomputed each `rebuildLayers(...)` call from the
    /// inputs above plus the active drag preview.
    private var lastLayout: TimelineLayout?
    /// Dedicated overlay layer for the playhead vertical line. Updated in
    /// `setPlayhead(time:)` without rebuilding the rest of the tree, so
    /// the ~30fps PreviewPlayer time observer doesn't churn the entire
    /// CALayer hierarchy. The companion "head" pentagon lives on the
    /// floating `StickyRulerView` instead so it stays visible when the
    /// user scrolls past the ruler.
    private var playheadLineLayer: CALayer?

    /// In-progress drag state. nil = not dragging; non-nil = dragging.
    /// On mouseUp: the deltaPixels is converted to a RationalTime and an
    /// EditCommand is dispatched via `onApplyCommand`. Scrub drags are
    /// also tracked here (Kind.scrub) but their mouseUp doesn't post a
    /// command — scrubbing emits onScrub on each tick.
    private struct DragSession {
        enum Kind {
            case move
            case trimIn
            case trimOut
            case scrub
            case moveEffect
            case trimEffectIn
            case trimEffectOut
        }
        var kind: Kind
        var clipID: ClipID?              // set for clip kinds; nil otherwise
        var effectKeyframeID: EffectKeyframeID?  // set for effect kinds
        var startPoint: CGPoint
        var currentDeltaPixels: CGFloat
    }
    private var dragSession: DragSession?

    public override var isFlipped: Bool { true }
    public override var acceptsFirstResponder: Bool { true }

    public init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        layer?.masksToBounds = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    public func update(project: Project, bundleURL: URL?, pixelsPerSecond: CGFloat, trackHeight: CGFloat, scrollX: CGFloat, selectedClipID: ClipID?, selectedEffectKeyframeID: EffectKeyframeID?, revision: Int) {
        let snapshot = InputSnapshot(
            bundleURL: bundleURL,
            pixelsPerSecond: pixelsPerSecond,
            trackHeight: trackHeight,
            scrollX: scrollX,
            selectedClipID: selectedClipID,
            selectedEffectKeyframeID: selectedEffectKeyframeID,
            revision: revision
        )
        // Skip the full layer rebuild when nothing the layout depends on
        // has changed. The playhead path (`setPlayhead(time:)`) runs
        // independently — its caller invokes it after `update`. The
        // PreviewPlayer's ~30fps time observer fires `updateNSView`
        // continuously during playback; without this gate we'd rebuild
        // every CALayer ~30 times per second.
        if lastInputs == snapshot && self.project != nil {
            self.project = project
            return
        }
        self.project = project
        self.bundleURL = bundleURL
        self.pixelsPerSecond = pixelsPerSecond
        self.trackHeight = trackHeight
        self.scrollX = scrollX
        self.selectedClipID = selectedClipID
        self.selectedEffectKeyframeID = selectedEffectKeyframeID
        self.lastInputs = snapshot
        needsLayout = true
        rebuildLayers()
    }

    private func rebuildLayers() {
        guard let project, let layer else { return }
        let viewport = TimelineViewport(
            size: bounds.size == .zero ? CGSize(width: 800, height: 240) : bounds.size,
            pixelsPerSecond: pixelsPerSecond,
            scrollX: scrollX,
            trackHeight: trackHeight
        )
        let preview = currentDragPreview()
        let layout = TimelineLayoutCalculator.layout(project: project, viewport: viewport, dragPreview: preview)
        lastLayout = layout

        // Mid-drag rebuilds happen on every mouseDragged (often dozens of
        // times per second). Wrap the layer mutation in a CATransaction
        // with no implicit animation so the preview doesn't smear.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        layer.sublayers?.removeAll()
        // The playhead line lives in our sublayer tree; the removeAll
        // above dropped it. Drop the reference too so setPlayhead lazy-
        // adds a fresh layer the next time it runs. The ruler strip +
        // playhead head live on the floating `StickyRulerView` and are
        // not affected.
        playheadLineLayer = nil

        // The first `rulerHeight + verticalInset` of document-y is left
        // empty on purpose — when the user is scrolled to top, the
        // floating ruler covers it exactly; when scrolled further down,
        // it's the standard sticky-header trade-off (top of lane 1 sits
        // briefly under the floating ruler as it scrolls past).

        for track in layout.tracks {
            // Header cell.
            let header = CATextLayer()
            header.frame = track.headerFrame
            header.string = "\(track.name) (\(track.kind.rawValue))"
            header.fontSize = 11
            header.alignmentMode = .left
            header.contentsScale = window?.backingScaleFactor ?? 2
            header.foregroundColor = NSColor.secondaryLabelColor.cgColor
            header.backgroundColor = NSColor.controlBackgroundColor.cgColor
            layer.addSublayer(header)

            // Lane background.
            let lane = CALayer()
            lane.frame = track.laneFrame
            lane.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.4).cgColor
            layer.addSublayer(lane)

            // Clips.
            for clip in track.clips {
                let clipLayer = CALayer()
                clipLayer.frame = clip.frame
                clipLayer.cornerRadius = 4
                clipLayer.borderWidth = clip.id == selectedClipID ? 2 : 1
                clipLayer.borderColor = clip.id == selectedClipID
                    ? NSColor.controlAccentColor.cgColor
                    : NSColor.separatorColor.cgColor
                clipLayer.backgroundColor = colorForKind(track.kind, selected: clip.id == selectedClipID).cgColor
                layer.addSublayer(clipLayer)

                // Audio tracks get a waveform overlay inside the clip
                // body. Loading is async; while it's in flight the
                // overlay just renders empty (the clip's tinted
                // background is the placeholder).
                if isAudioKind(track.kind) {
                    addWaveformLayer(forClip: clip, clipFrame: clip.frame, kind: track.kind)
                }
            }
        }

        let effectsLane = layout.effectsLane
        let effectsHeader = CATextLayer()
        effectsHeader.frame = effectsLane.headerFrame
        effectsHeader.string = "Effects"
        effectsHeader.fontSize = 11
        effectsHeader.alignmentMode = .left
        effectsHeader.contentsScale = window?.backingScaleFactor ?? 2
        effectsHeader.foregroundColor = NSColor.secondaryLabelColor.cgColor
        effectsHeader.backgroundColor = NSColor.controlBackgroundColor.cgColor
        layer.addSublayer(effectsHeader)

        let effectsLaneBg = CALayer()
        effectsLaneBg.frame = effectsLane.laneFrame
        effectsLaneBg.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.4).cgColor
        layer.addSublayer(effectsLaneBg)

        for keyframe in effectsLane.keyframes {
            let isSelected = keyframe.id == selectedEffectKeyframeID
            let kfLayer = CALayer()
            kfLayer.frame = keyframe.frame
            kfLayer.cornerRadius = 4
            kfLayer.borderWidth = isSelected ? 2 : 1
            kfLayer.borderColor = isSelected
                ? NSColor.controlAccentColor.cgColor
                : NSColor.separatorColor.cgColor
            kfLayer.backgroundColor = colorForEffectKeyframe(keyframe, selected: isSelected).cgColor
            layer.addSublayer(kfLayer)

            // Small ⌘ glyph in the top-left for manual-hotkey keyframes so
            // the user can tell at a glance which were AI-guessed vs
            // intentionally stamped. Skip when the keyframe is too narrow.
            if keyframe.origin == .manualHotkey, keyframe.frame.width >= 24 {
                let glyph = CATextLayer()
                glyph.string = "⌘"
                glyph.fontSize = 11
                glyph.foregroundColor = NSColor.labelColor.cgColor
                glyph.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
                glyph.alignmentMode = .left
                glyph.frame = CGRect(
                    x: keyframe.frame.minX + 4,
                    y: keyframe.frame.minY + 2,
                    width: 14,
                    height: 14
                )
                layer.addSublayer(glyph)
            }
        }

        // Re-establish the playhead overlay on top of the newly-rebuilt
        // clip tree. setPlayhead is a fast no-op if `playheadTime` is nil.
        setPlayhead(time: playheadTime)
    }

    private func currentDragPreview() -> TimelineDragPreview {
        guard let session = dragSession else { return .none }
        switch session.kind {
        case .move:
            guard let clipID = session.clipID else { return .none }
            return .moveClip(clipID, deltaPixels: session.currentDeltaPixels)
        case .trimIn:
            guard let clipID = session.clipID else { return .none }
            return .trimIn(clipID, deltaPixels: session.currentDeltaPixels)
        case .trimOut:
            guard let clipID = session.clipID else { return .none }
            return .trimOut(clipID, deltaPixels: session.currentDeltaPixels)
        case .scrub: return .none
        case .moveEffect:
            guard let id = session.effectKeyframeID else { return .none }
            return .moveEffectKeyframe(id, deltaPixels: session.currentDeltaPixels)
        case .trimEffectIn:
            guard let id = session.effectKeyframeID else { return .none }
            return .trimEffectKeyframeIn(id, deltaPixels: session.currentDeltaPixels)
        case .trimEffectOut:
            guard let id = session.effectKeyframeID else { return .none }
            return .trimEffectKeyframeOut(id, deltaPixels: session.currentDeltaPixels)
        }
    }

    private func colorForKind(_ kind: TrackKind, selected: Bool) -> NSColor {
        let base: NSColor
        switch kind {
        case .screen:        base = .systemBlue
        case .webcam:        base = .systemTeal
        case .microphone:    base = .systemGreen
        case .systemAudio:   base = .systemMint
        case .voiceover:     base = .systemOrange
        case .overlay:       base = .systemPurple
        case .effects:       base = .systemPink
        }
        return base.withAlphaComponent(selected ? 0.55 : 0.35)
    }

    private func colorForEffectKeyframe(
        _ keyframe: EffectKeyframeLayout,
        selected: Bool = false
    ) -> NSColor {
        let base: NSColor
        switch (keyframe.kind, keyframe.origin) {
        case (.zoom, .auto):            base = .systemYellow
        case (.zoom, .manualHotkey):    base = .systemCyan
        case (.talkingHeadSwap, _):     base = .systemIndigo
        }
        return base.withAlphaComponent(selected ? 0.75 : 0.55)
    }

    private func isAudioKind(_ kind: TrackKind) -> Bool {
        switch kind {
        case .microphone, .systemAudio, .voiceover: return true
        case .screen, .webcam, .overlay, .effects: return false
        }
    }

    /// Adds a WaveformLayer above the clip's body and kicks off an async
    /// load via WaveformLoader. Resolves the asset URL by joining
    /// `bundleURL` with the MediaAsset's `relativePath`. Missing asset
    /// or no bundleURL → silently skips the waveform (the clip's tinted
    /// background still shows; the user just doesn't get the audio
    /// preview yet).
    private func addWaveformLayer(forClip clip: ClipLayout, clipFrame: CGRect, kind: TrackKind) {
        guard let project, let bundleURL else { return }
        guard let modelClip = project.tracks.flatMap(\.clips).first(where: { $0.id == clip.id }) else { return }
        guard let asset = project.assets.first(where: { $0.id == modelClip.assetID }) else { return }
        let assetURL = bundleURL.appendingPathComponent(asset.relativePath)
        let waveform = WaveformLayer()
        // Inset the waveform inside the clip frame so the rounded clip
        // border still shows around the edges.
        let inset: CGFloat = 4
        waveform.frame = CGRect(
            x: clipFrame.minX + inset,
            y: clipFrame.minY + inset,
            width: max(0, clipFrame.width - inset * 2),
            height: max(0, clipFrame.height - inset * 2)
        )
        waveform.fillColor = NSColor.labelColor.withAlphaComponent(0.55).cgColor
        waveform.contentsScale = window?.backingScaleFactor ?? 2
        layer?.addSublayer(waveform)

        let buckets = max(8, Int(waveform.frame.width))  // ~1 bucket per pixel
        let startSeconds = seconds(modelClip.sourceRange.start)
        let durationSeconds = seconds(modelClip.sourceRange.duration)
        let loader = waveformLoader
        // Stay on the main actor: `loader.peaks(...)` is an actor func so
        // its body still hops to the loader's actor for I/O. Keeping the
        // surrounding Task @MainActor lets us safely capture the
        // (non-Sendable) WaveformLayer reference. Strong ref is fine —
        // the load takes ~1s and the layer is dropped on next rebuild.
        Task { @MainActor [weak waveform] in
            do {
                let peaks = try await loader.peaks(
                    forAssetAt: assetURL,
                    startSeconds: startSeconds,
                    durationSeconds: durationSeconds,
                    buckets: buckets
                )
                waveform?.peaks = peaks
            } catch {
                // Best-effort: log and leave the waveform empty. Recording
                // still plays back fine via the existing PreviewPlayer.
                log.error("waveform load failed url=\(assetURL.lastPathComponent, privacy: .public): \(String(describing: error), privacy: .public)")
            }
        }
    }

    // MARK: - Cursor

    public override func resetCursorRects() {
        super.resetCursorRects()
        guard let lastLayout else { return }
        for track in lastLayout.tracks {
            for clip in track.clips {
                addBodyAndEdgeCursors(frame: clip.frame)
            }
        }
        for kf in lastLayout.effectsLane.keyframes {
            addBodyAndEdgeCursors(frame: kf.frame)
        }
    }

    private func addBodyAndEdgeCursors(frame: CGRect) {
        guard frame.width >= TimelineHitTest.edgeZoneWidth * 3 else {
            addCursorRect(frame, cursor: .openHand)
            return
        }
        let leftEdge = CGRect(
            x: frame.minX,
            y: frame.minY,
            width: TimelineHitTest.edgeZoneWidth,
            height: frame.height
        )
        let rightEdge = CGRect(
            x: frame.maxX - TimelineHitTest.edgeZoneWidth,
            y: frame.minY,
            width: TimelineHitTest.edgeZoneWidth,
            height: frame.height
        )
        let body = CGRect(
            x: leftEdge.maxX,
            y: frame.minY,
            width: rightEdge.minX - leftEdge.maxX,
            height: frame.height
        )
        addCursorRect(leftEdge, cursor: .resizeLeftRight)
        addCursorRect(rightEdge, cursor: .resizeLeftRight)
        addCursorRect(body, cursor: .openHand)
    }

    // MARK: - Playhead

    /// Updates the playhead line's x position. Called from the SwiftUI
    /// host on every PreviewPlayer time-observer tick (~30fps); does not
    /// rebuild any clip layers. The companion "head" pentagon lives on
    /// the floating `StickyRulerView` and is updated separately by the
    /// host via `rulerHost.playheadTime = ...`.
    public func setPlayhead(time: RationalTime?) {
        playheadTime = time
        guard let layer else { return }
        let viewport = TimelineViewport(
            size: bounds.size == .zero ? CGSize(width: 800, height: 240) : bounds.size,
            pixelsPerSecond: pixelsPerSecond,
            scrollX: scrollX,
            trackHeight: trackHeight
        )
        guard let time, let lastLayout else {
            playheadLineLayer?.isHidden = true
            return
        }
        let secs = CGFloat(seconds(time))
        let x = TimelineLayoutCalculator.viewportX(forTimelineSeconds: secs, viewport: viewport)
        // Hide the playhead if it would land behind the track-header column.
        // (Off the right edge is fine — the ScrollView will clip it.)
        guard x >= TimelineLayoutCalculator.trackHeaderWidth else {
            playheadLineLayer?.isHidden = true
            return
        }

        if playheadLineLayer == nil {
            let l = CALayer()
            l.backgroundColor = NSColor.controlAccentColor.cgColor
            l.zPosition = 1000  // above all clip layers
            layer.addSublayer(l)
            playheadLineLayer = l
        }
        playheadLineLayer?.isHidden = false

        // Wrap in a no-animation CATransaction so per-frame updates
        // don't smear across the redraw boundary.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playheadLineLayer?.frame = CGRect(
            x: x,
            y: 0,
            width: 1,
            height: lastLayout.totalContentHeight
        )
        CATransaction.commit()
    }

    // MARK: - Mouse handling

    public override func mouseDown(with event: NSEvent) {
        guard let lastLayout else { return }
        let point = convert(event.locationInWindow, from: nil)
        let hit = TimelineHitTest.hit(at: point, in: lastLayout)
        let optionHeld = event.modifierFlags.contains(.option)

        switch hit {
        case .clipBody(let clipID, _):
            onSelect?(clipID)
            onSelectEffectKeyframe?(nil)
            // ⌥-click on the body splits at the click point — common DAW
            // convention. We deliberately don't honour ⌥ on the edge zones;
            // those stay as trim handles to avoid the user accidentally
            // splitting at the very start/end of a clip (which the
            // SplitClipCommand bounds-check would reject anyway).
            if optionHeld {
                postSplit(at: point, clipID: clipID)
                dragSession = nil
            } else {
                dragSession = DragSession(kind: .move, clipID: clipID, effectKeyframeID: nil, startPoint: point, currentDeltaPixels: 0)
            }
        case .clipLeftEdge(let clipID, _):
            onSelect?(clipID)
            onSelectEffectKeyframe?(nil)
            dragSession = DragSession(kind: .trimIn, clipID: clipID, effectKeyframeID: nil, startPoint: point, currentDeltaPixels: 0)
        case .clipRightEdge(let clipID, _):
            onSelect?(clipID)
            onSelectEffectKeyframe?(nil)
            dragSession = DragSession(kind: .trimOut, clipID: clipID, effectKeyframeID: nil, startPoint: point, currentDeltaPixels: 0)
        case .ruler:
            onSelect?(nil)
            onSelectEffectKeyframe?(nil)
            postScrub(at: point)
            dragSession = DragSession(kind: .scrub, clipID: nil, effectKeyframeID: nil, startPoint: point, currentDeltaPixels: 0)
        case .effectKeyframeBody(let kfID):
            onSelect?(nil)
            onSelectEffectKeyframe?(kfID)
            window?.makeFirstResponder(self)
            dragSession = DragSession(kind: .moveEffect, clipID: nil, effectKeyframeID: kfID, startPoint: point, currentDeltaPixels: 0)
        case .effectKeyframeLeftEdge(let kfID):
            onSelect?(nil)
            onSelectEffectKeyframe?(kfID)
            window?.makeFirstResponder(self)
            dragSession = DragSession(kind: .trimEffectIn, clipID: nil, effectKeyframeID: kfID, startPoint: point, currentDeltaPixels: 0)
        case .effectKeyframeRightEdge(let kfID):
            onSelect?(nil)
            onSelectEffectKeyframe?(kfID)
            window?.makeFirstResponder(self)
            dragSession = DragSession(kind: .trimEffectOut, clipID: nil, effectKeyframeID: kfID, startPoint: point, currentDeltaPixels: 0)
        case .emptyEffectsLane:
            onSelect?(nil)
            // ⌥-click adds a new zoom keyframe at the click point. Default
            // duration is 1.5s (0.2s ease-in + 1.1s hold + 0.2s ease-out)
            // matching `EffectKeyframe`'s init defaults; subsequent drag
            // edits resize it. Without the option modifier, treat as
            // deselect — consistent with the empty-track-lane behaviour.
            if optionHeld {
                postAddKeyframe(at: point)
            } else {
                onSelectEffectKeyframe?(nil)
            }
            dragSession = nil
        case .effectsLaneHeader:
            onSelectEffectKeyframe?(nil)
            dragSession = nil
        case .trackHeader, .emptyLane, .empty:
            onSelect?(nil)
            onSelectEffectKeyframe?(nil)
            dragSession = nil
        }
    }

    private func postAddKeyframe(at point: CGPoint) {
        let viewport = TimelineViewport(
            size: bounds.size == .zero ? CGSize(width: 800, height: 240) : bounds.size,
            pixelsPerSecond: pixelsPerSecond,
            scrollX: scrollX,
            trackHeight: trackHeight
        )
        let secs = TimelineLayoutCalculator.timelineSeconds(forViewportX: point.x, viewport: viewport)
        let kf = EffectKeyframe(
            kind: .zoom,
            timelineRange: TimeRange(
                start: .seconds(Double(secs)),
                duration: .seconds(1.5)
            )
        )
        onApplyCommand?(AddEffectKeyframeCommand(keyframe: kf))
        onSelectEffectKeyframe?(kf.id)
    }

    private func postScrub(at point: CGPoint) {
        let viewport = TimelineViewport(
            size: bounds.size == .zero ? CGSize(width: 800, height: 240) : bounds.size,
            pixelsPerSecond: pixelsPerSecond,
            scrollX: scrollX,
            trackHeight: trackHeight
        )
        let secs = TimelineLayoutCalculator.timelineSeconds(forViewportX: point.x, viewport: viewport)
        onScrub?(RationalTime.seconds(Double(secs)))
    }

    private func postSplit(at point: CGPoint, clipID: ClipID) {
        let viewport = TimelineViewport(
            size: bounds.size == .zero ? CGSize(width: 800, height: 240) : bounds.size,
            pixelsPerSecond: pixelsPerSecond,
            scrollX: scrollX,
            trackHeight: trackHeight
        )
        let secs = TimelineLayoutCalculator.timelineSeconds(forViewportX: point.x, viewport: viewport)
        let splitTime = RationalTime.seconds(Double(secs))
        onApplyCommand?(SplitClipCommand(clipID: clipID, splitTime: splitTime))
    }

    public override func mouseDragged(with event: NSEvent) {
        guard var session = dragSession else { return }
        let point = convert(event.locationInWindow, from: nil)
        session.currentDeltaPixels = point.x - session.startPoint.x
        dragSession = session
        if session.kind == .scrub {
            // Scrub fires per-tick (no commit on mouseUp; the player is
            // already at the dragged time). No layer rebuild — the
            // playhead follows the player via setPlayhead(time:) on the
            // next SwiftUI update tick.
            postScrub(at: point)
        } else {
            rebuildLayers()
        }
    }

    public override func mouseUp(with event: NSEvent) {
        guard let session = dragSession else { return }
        defer {
            dragSession = nil
            rebuildLayers()
        }
        // Scrub doesn't produce an EditCommand on mouseUp.
        if session.kind == .scrub { return }
        let pps = max(TimelineLayoutCalculator.minPixelsPerSecond,
                      min(TimelineLayoutCalculator.maxPixelsPerSecond, pixelsPerSecond))
        let deltaSeconds = Double(session.currentDeltaPixels / pps)
        // Threshold: ignore micro-drags (< 1pt) so a click that moves a
        // hair while the user releases the mouse doesn't churn an undo
        // entry.
        guard abs(session.currentDeltaPixels) >= 1 else { return }
        let delta = RationalTime.seconds(deltaSeconds)
        switch session.kind {
        case .move:
            guard let clipID = session.clipID else { return }
            // Move uses an absolute newTimelineStart, so we add delta to
            // the clip's current start.
            guard let clip = project?.clip(clipID) else { return }
            let newStart = RationalTime.seconds(
                seconds(clip.timelineRange.start) + deltaSeconds
            )
            onApplyCommand?(MoveClipCommand(clipID: clipID, newTimelineStart: newStart))
        case .trimIn:
            guard let clipID = session.clipID else { return }
            onApplyCommand?(TrimClipInCommand(clipID: clipID, delta: delta))
        case .trimOut:
            guard let clipID = session.clipID else { return }
            onApplyCommand?(TrimClipOutCommand(clipID: clipID, delta: delta))
        case .moveEffect, .trimEffectIn, .trimEffectOut:
            guard let kfID = session.effectKeyframeID,
                  let original = project?.effects.first(where: { $0.id == kfID }) else { return }
            let oldStart = seconds(original.timelineRange.start)
            let oldDuration = seconds(original.timelineRange.duration)
            // Floor for any keyframe duration — keeps the segment visible
            // at minimum zoom (1pt at maxPixelsPerSecond = 1/800s) and
            // sidesteps the command's "duration must be > 0" guard.
            let minDuration: Double = 0.01
            var newStartSec = oldStart
            var newDurationSec = oldDuration
            switch session.kind {
            case .moveEffect:
                newStartSec = max(0, oldStart + deltaSeconds)
            case .trimEffectIn:
                let clamped = min(deltaSeconds, oldDuration - minDuration)
                newStartSec = max(0, oldStart + clamped)
                newDurationSec = oldDuration - clamped
            case .trimEffectOut:
                newDurationSec = max(minDuration, oldDuration + deltaSeconds)
            default:
                break
            }
            guard newStartSec != oldStart || newDurationSec != oldDuration else { return }
            let updated = EffectKeyframe(
                id: original.id,
                kind: original.kind,
                timelineRange: TimeRange(
                    start: .seconds(newStartSec),
                    duration: .seconds(newDurationSec)
                ),
                zoomFactor: original.zoomFactor,
                centerX: original.centerX,
                centerY: original.centerY,
                easeIn: original.easeIn,
                easeOut: original.easeOut,
                extras: original.extras
            )
            onApplyCommand?(UpdateEffectKeyframeCommand(keyframeID: kfID, newValue: updated))
        case .scrub:
            // Already returned above; this case for exhaustiveness.
            break
        }
    }

    // MARK: - Keyboard

    public override func keyDown(with event: NSEvent) {
        // Delete / Backspace removes the selected effect keyframe. Clip
        // deletion is currently driven via the Inspector "Remove" button —
        // not wired here to avoid surprising the user with a destructive
        // hotkey on a timeline that doesn't yet have multi-clip selection.
        let isDelete = event.keyCode == 51 || event.keyCode == 117
        if isDelete, let id = selectedEffectKeyframeID {
            onApplyCommand?(RemoveEffectKeyframeCommand(keyframeID: id))
            onSelectEffectKeyframe?(nil)
            return
        }
        super.keyDown(with: event)
    }

    private func seconds(_ t: RationalTime) -> Double {
        guard t.timescale != 0 else { return 0 }
        return Double(t.value) / Double(t.timescale)
    }
}

/// NSView host for the sticky ruler. Lives as a floating subview of the
/// timeline's NSScrollView (`addFloatingSubview(_:for: .vertical)`) so
/// it stays pinned to the top of the viewport during vertical scroll
/// while still scrolling horizontally with the document content — tick
/// alignment with clip frames holds at every scroll position.
///
/// Also owns the playhead "head" pentagon. Putting the head here means
/// it stays visible inside the sticky ruler even when the user scrolls
/// past the document's ruler region; the companion vertical line is
/// still drawn into `TimelineNSView` so it spans the lanes.
///
/// Sized in viewport-flipped coords by `TimelineView.sizeDocumentView`:
/// the view's full width equals the document's content width and AppKit
/// clips during draw. We render ticks in absolute document-x (no
/// `scrollSeconds` math), matching the horizontal scroll naturally.
public final class StickyRulerView: NSView {
    private let rulerLayer = RulerLayer()
    private let playheadHead = CAShapeLayer()
    var onScrub: ((RationalTime) -> Void)?

    var pixelsPerSecond: CGFloat = TimelineLayoutCalculator.defaultPixelsPerSecond {
        didSet {
            rulerLayer.pixelsPerSecond = pixelsPerSecond
            updatePlayheadHead()
        }
    }

    var playheadTime: RationalTime? {
        didSet { updatePlayheadHead() }
    }

    public override var isFlipped: Bool { true }

    public init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        rulerLayer.scrollSeconds = 0  // we span the document; absolute x
        rulerLayer.headerWidth = TimelineLayoutCalculator.trackHeaderWidth
        rulerLayer.pixelsPerSecond = pixelsPerSecond
        layer?.addSublayer(rulerLayer)
        configurePlayheadHead()
        layer?.addSublayer(playheadHead)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    public override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        rulerLayer.frame = bounds
        rulerLayer.contentsScale = window?.backingScaleFactor ?? 2
        rulerLayer.setNeedsDisplay()
        updatePlayheadHead()
        CATransaction.commit()
    }

    private func configurePlayheadHead() {
        let w: CGFloat = 12
        let h = TimelineLayoutCalculator.rulerHeight
        let pointHeight: CGFloat = 4
        let topHeight = h - pointHeight
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 0, y: 0))
        path.addLine(to: CGPoint(x: w, y: 0))
        path.addLine(to: CGPoint(x: w, y: topHeight))
        path.addLine(to: CGPoint(x: w / 2, y: h))
        path.addLine(to: CGPoint(x: 0, y: topHeight))
        path.closeSubpath()
        playheadHead.path = path
        playheadHead.fillColor = NSColor.controlAccentColor.cgColor
        playheadHead.strokeColor = NSColor.controlAccentColor.cgColor
        playheadHead.zPosition = 1
        playheadHead.isHidden = true
    }

    private func updatePlayheadHead() {
        guard let time = playheadTime else {
            playheadHead.isHidden = true
            return
        }
        let pps = max(TimelineLayoutCalculator.minPixelsPerSecond,
                      min(TimelineLayoutCalculator.maxPixelsPerSecond, pixelsPerSecond))
        let secs = CGFloat(seconds(time))
        let x = TimelineLayoutCalculator.trackHeaderWidth + secs * pps
        guard x >= TimelineLayoutCalculator.trackHeaderWidth, x <= bounds.maxX else {
            playheadHead.isHidden = true
            return
        }
        playheadHead.isHidden = false
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let headWidth: CGFloat = 12
        playheadHead.frame = CGRect(
            x: x - headWidth / 2,
            y: 0,
            width: headWidth,
            height: TimelineLayoutCalculator.rulerHeight
        )
        CATransaction.commit()
    }

    // MARK: - Click + drag scrubbing
    // Mirrors `TimelineNSView`'s `.ruler` hit-zone behaviour. The
    // document-resident ruler used to receive these clicks; with the
    // floating ruler now covering that area, we forward scrub events
    // from here. Clicks landing in the track-header column (x < headerWidth)
    // are ignored.

    public override func mouseDown(with event: NSEvent) {
        postScrub(at: convert(event.locationInWindow, from: nil))
    }

    public override func mouseDragged(with event: NSEvent) {
        postScrub(at: convert(event.locationInWindow, from: nil))
    }

    private func postScrub(at point: CGPoint) {
        guard point.x >= TimelineLayoutCalculator.trackHeaderWidth else { return }
        let pps = max(TimelineLayoutCalculator.minPixelsPerSecond,
                      min(TimelineLayoutCalculator.maxPixelsPerSecond, pixelsPerSecond))
        let secs = max(0, (point.x - TimelineLayoutCalculator.trackHeaderWidth) / pps)
        onScrub?(RationalTime.seconds(Double(secs)))
    }

    private func seconds(_ t: RationalTime) -> Double {
        guard t.timescale != 0 else { return 0 }
        return Double(t.value) / Double(t.timescale)
    }
}
#endif
